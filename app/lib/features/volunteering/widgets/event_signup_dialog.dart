import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/roles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/role_details_link.dart';
import '../../auth_invites/state/auth_provider.dart';
import '../models/signup_model.dart';
import '../state/volunteering_provider.dart';

class EventSignupDialog extends ConsumerStatefulWidget {
  final String sku;
  final String eventName;
  final EventSignupModel? existingSignup;

  const EventSignupDialog({
    super.key,
    required this.sku,
    required this.eventName,
    this.existingSignup,
  });

  @override
  ConsumerState<EventSignupDialog> createState() => _EventSignupDialogState();
}

class _EventSignupDialogState extends ConsumerState<EventSignupDialog> {
  late SignupStatus _status;
  late Set<String> _selectedRoles;
  bool _initializedDefaultRoles = false;
  final _otherRoleController = TextEditingController();
  final _notesController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final s = widget.existingSignup;
    _status = s?.status ?? SignupStatus.available;
    _selectedRoles = Set<String>.from(s?.offeredRoles ?? []);
    _otherRoleController.text = s?.otherRoleDescription ?? '';
    _notesController.text = s?.notes ?? '';

    if (s != null) {
      _initializedDefaultRoles = true;
    } else {
      // If new signup, pre-select roles marked "Favourite" in account preferences
      final user = ref.read(currentVolunteerProvider);
      if (user != null) {
        _selectedRoles = Set<String>.from(user.defaultEventRoles);
        _initializedDefaultRoles = true;
      }
    }
  }

  @override
  void dispose() {
    _otherRoleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(currentVolunteerProvider);
    if (user == null) return;

    if (_selectedRoles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one role you can take.')),
      );
      return;
    }

    if (_selectedRoles.contains('other') && _otherRoleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a description for "Other" role.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(volunteerRepositoryProvider);
      await repo.saveSignup(
        sku: widget.sku,
        volunteer: user,
        status: _status,
        offeredRoles: _selectedRoles.toList(),
        otherRoleDescription: _selectedRoles.contains('other') ? _otherRoleController.text.trim() : null,
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
      );

      // Invalidate queries so UI updates immediately
      ref.invalidate(eventSignupsProvider(widget.sku));
      ref.invalidate(userEventSignupProvider(widget.sku));
      ref.invalidate(myVolunteerSignupsProvider);

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _status == SignupStatus.confirmed
                  ? 'Confirmed for event! Event Partner has been notified.'
                  : 'Marked as Available for event.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving signup: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _withdraw() async {
    final user = ref.read(currentVolunteerProvider);
    if (user == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw from Event?'),
        content: Text(
          'Are you sure you want to pull out of "${widget.eventName}"? Your signup will be removed immediately from the roster.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Yes, Withdraw'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(volunteerRepositoryProvider);
      await repo.withdrawSignup(sku: widget.sku, volunteerId: user.id);

      ref.invalidate(eventSignupsProvider(widget.sku));
      ref.invalidate(userEventSignupProvider(widget.sku));
      ref.invalidate(myVolunteerSignupsProvider);

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have successfully withdrawn from this event.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error withdrawing: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentVolunteerProvider);
    if (user == null) return const SizedBox();

    if (!_initializedDefaultRoles) {
      _selectedRoles = Set<String>.from(user.defaultEventRoles);
      _initializedDefaultRoles = true;
    }

    const availableRoles = VolunteerRole.values;

    final isExisting = widget.existingSignup != null;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: Column(
          children: [
            // Title Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
              child: Row(
                children: [
                  Icon(
                    isExisting ? Icons.edit_calendar : Icons.how_to_reg,
                    color: AppTheme.brandGreen,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isExisting ? 'Update Volunteer Signup' : 'Volunteer for Event',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.eventName,
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Form Body
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Availability Status Selector
                    const Text(
                      'Your Status for this Event',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),

                    SegmentedButton<SignupStatus>(
                      segments: const [
                        ButtonSegment(
                          value: SignupStatus.available,
                          icon: Icon(Icons.event_available, color: AppTheme.statusAvailable),
                          label: Text('Available'),
                        ),
                        ButtonSegment(
                          value: SignupStatus.confirmed,
                          icon: Icon(Icons.check_circle, color: AppTheme.statusConfirmed),
                          label: Text('Confirmed'),
                        ),
                      ],
                      selected: {_status},
                      onSelectionChanged: (newSelection) {
                        setState(() => _status = newSelection.first);
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status == SignupStatus.available
                          ? 'Available: Indicates you are free and would like to help at this event.'
                          : 'Confirmed: Indicates a committed reservation to attend and volunteer.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 20),

                    // Role Selection (All official roles offered; profile preferred roles pre-selected on new signup)
                    const Text(
                      'Potential Roles You Can Take',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isExisting
                          ? 'Select all roles you can take for this event.'
                          : 'Your preferred roles from Profile are pre-selected. Select any roles you can take.',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 4),
                    const RoleDetailsLink(),
                    const SizedBox(height: 8),

                    ...availableRoles.map((role) {
                      final isSelected = _selectedRoles.contains(role.id);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: CheckboxListTile(
                          key: Key('event_signup_role_${role.id}'),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: isSelected ? role.color : const Color(0xFFE2E8F0),
                            ),
                          ),
                          dense: true,
                          secondary: Icon(role.icon, color: role.color, size: 20),
                          title: Text(
                            role.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? role.color : null,
                            ),
                          ),
                          subtitle: role.id == 'other'
                              ? const Text('Custom role not listed above', style: TextStyle(fontSize: 11))
                              : Text(role.description, style: const TextStyle(fontSize: 11)),
                          value: isSelected,
                          activeColor: role.color,
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                _selectedRoles.add(role.id);
                              } else {
                                _selectedRoles.remove(role.id);
                              }
                            });
                          },
                        ),
                      );
                    }),

                    // Other role textfield if 'other' is selected
                    if (_selectedRoles.contains('other')) ...[
                      const SizedBox(height: 6),
                      TextField(
                        controller: _otherRoleController,
                        decoration: const InputDecoration(
                          labelText: 'Specify Other Role *',
                          hintText: 'e.g. Setup Crew, Photographer, Event Support',
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Notes / Comments
                    const Text(
                      'Notes for Event Partner',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _notesController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Can arrive by 8:30am, travelling with Team 1234A...',
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Pull out button (if already signed up)
                    if (isExisting) ...[
                      const Divider(),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _isLoading ? null : _withdraw,
                        icon: const Icon(Icons.cancel_outlined, color: Colors.red, size: 18),
                        label: const Text(
                          'Pull Out / Withdraw from Event',
                          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const Divider(height: 1),
            // Actions
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _save,
                    child: _isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(isExisting ? 'Update Signup' : 'Sign Up as Volunteer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
