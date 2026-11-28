import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/roles.dart';
import '../../../core/routing/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth_invites/state/auth_provider.dart';
import '../models/volunteer_model.dart';
import '../widgets/role_preferences_selector.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  late Set<String> _qualifications;
  late Set<String> _preferredRoles;
  bool _initializedFromUser = false;
  final bool _isPhonePublic = false;
  final bool _isEmailPublic = false;
  final bool _forwardingEnabled = false;
  final bool _isEventPartner = false;

  void _syncFromUser(VolunteerModel user) {
    _nameController.text = user.name;
    _emailController.text = user.email;
    _phoneController.text = user.phone ?? '';
    _qualifications = Set<String>.from(user.qualifications)
      ..remove(VolunteerRole.other.id);
    _preferredRoles = Set<String>.from(user.defaultEventRoles)
      ..remove(VolunteerRole.other.id);
    _initializedFromUser = true;
  }

  @override
  void initState() {
    super.initState();
    _qualifications = <String>{};
    _preferredRoles = <String>{};
    final user = ref.read(currentVolunteerProvider);
    if (user != null) {
      _syncFromUser(user);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(currentVolunteerProvider);
    if (user == null) return;

    final cleanPreferred =
        _preferredRoles.where(_qualifications.contains).toList();

    final updated = user.copyWith(
      name: _nameController.text.trim(),
      email: _emailController.text.trim(),
      phone: _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null,
      qualifications: _qualifications.toList(),
      preferredRoles: cleanPreferred,
      isPhonePublic: _isPhonePublic,
      isEmailPublic: _isEmailPublic,
      forwardingEnabled: _forwardingEnabled,
      isEventPartner: _isEventPartner,
    );

    if (_nameController.text.trim().isEmpty || _qualifications.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide your name and select at least one qualification.'),
        ),
      );
      return;
    }

    await ref.read(authControllerProvider.notifier).updateProfile(updated);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile and privacy settings saved successfully.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentVolunteerProvider);
    final isAdmin = ref.watch(isAdminProvider);
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('No active volunteer session')),
      );
    }
    if (!_initializedFromUser) {
      _syncFromUser(user);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Volunteer Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log Out',
            onPressed: () async {
              final navigator = Navigator.of(context);
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Log Out?'),
                  content: const Text('Are you sure you want to log out of RoboVolunteers?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('Log Out'),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                await ref.read(authControllerProvider.notifier).logout();
                if (navigator.mounted) {
                  navigator.popUntil((route) => route.isFirst);
                }
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Avatar Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundColor: AppTheme.brandGreen,
                          child: Text(
                            user.name.isNotEmpty ? user.name[0].toUpperCase() : 'V',
                            style: const TextStyle(
                              fontSize: 28,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.name,
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                user.email,
                                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _isEventPartner
                                          ? AppTheme.epVerifiedGold.withValues(alpha: 0.15)
                                          : AppTheme.brandGreen.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      _isEventPartner ? '★ Event Partner (EP)' : 'Official Volunteer',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: _isEventPartner
                                            ? AppTheme.epVerifiedGold
                                            : AppTheme.brandGreen,
                                      ),
                                    ),
                                  ),
                                  if (isAdmin)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.epVerifiedGold
                                            .withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        'Admin',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.epVerifiedGold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (isAdmin) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      key: const Key('profile_admin_portal_tile'),
                      leading: const Icon(
                        Icons.admin_panel_settings_outlined,
                        color: AppTheme.brandGreen,
                      ),
                      title: const Text(
                        'Admin Portal',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text(
                        'Generate one-time volunteer invite codes & shareable links',
                        style: TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () {
                        AppRouter.push(context, AppRoutes.admin);
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // Personal Info Card
                const Text(
                  'Account Details',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(labelText: 'Full Name'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _emailController,
                          readOnly: true,
                          decoration: const InputDecoration(
                            labelText: 'Verified Login Email',
                            helperText: 'Verified via 6-digit email passcode',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _phoneController,
                          decoration: const InputDecoration(labelText: 'Phone Number (Optional)'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Qualifications & Preferred Roles
                RolePreferencesSelector(
                  title: 'Qualifications & Role Preferences',
                  qualifications: _qualifications,
                  preferredRoles: _preferredRoles,
                  onQualificationChanged: (roleId, isQualified) {
                    setState(() {
                      if (isQualified) {
                        _qualifications.add(roleId);
                      } else {
                        _qualifications.remove(roleId);
                        _preferredRoles.remove(roleId);
                      }
                    });
                  },
                  onPreferredChanged: (roleId, isPreferred) {
                    setState(() {
                      if (isPreferred) {
                        _qualifications.add(roleId);
                        _preferredRoles.add(roleId);
                      } else {
                        _preferredRoles.remove(roleId);
                      }
                    });
                  },
                ),
                const SizedBox(height: 24),

                // Privacy & Forwarding Settings
                const Text(
                  'Contact Privacy & Email Forwarding',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose whether to display your raw contact details or use your anonymized forwarding relay address.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 10),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.shield_outlined, color: Colors.blue, size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Your Anonymized Forwarding Alias:',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    Text(
                                      user.forwardingAddress,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blue,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Use Email Forwarding Alias', style: TextStyle(fontSize: 14)),
                          subtitle: const Text(
                            'Displays your relay alias instead of your personal inbox',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _forwardingEnabled,
                          onChanged: null,
                        ),
                        const Divider(),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Make Phone Number Public', style: TextStyle(fontSize: 14)),
                          subtitle: const Text(
                            'Display phone directly on event rosters',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _isPhonePublic,
                          onChanged: null,
                        ),
                        const Divider(),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Make Email Address Public', style: TextStyle(fontSize: 14)),
                          subtitle: const Text(
                            'Display raw email directly on event rosters',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _isEmailPublic,
                          onChanged: null,
                        ),
                        const Divider(),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Event Partner (EP) Mode', style: TextStyle(fontSize: 14)),
                          subtitle: const Text(
                            'Enables verification checkmark and volunteer locking tools for event organizers',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _isEventPartner,
                          onChanged: null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text(
                    'Save Profile & Settings',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
