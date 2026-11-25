import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../profile/widgets/role_preferences_selector.dart';
import '../state/auth_provider.dart';

class SignupScreen extends ConsumerStatefulWidget {
  final String verifiedEmail;
  final String? initialName;

  const SignupScreen({
    super.key,
    required this.verifiedEmail,
    this.initialName,
  });

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  final _phoneController = TextEditingController();

  final Set<String> _selectedQualifications = {'head_ref', 'ref'};
  final Set<String> _selectedPreferredRoles = {'head_ref', 'ref'};
  final bool _isPhonePublic = false;
  final bool _isEmailPublic = false;
  final bool _forwardingEnabled = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedQualifications.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one qualification.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final cleanPreferred = _selectedPreferredRoles
          .where(_selectedQualifications.contains)
          .toList();
      await ref.read(authControllerProvider.notifier).completeOnboarding(
            name: _nameController.text.trim(),
            phone: _phoneController.text.trim().isNotEmpty
                ? _phoneController.text.trim()
                : null,
            qualifications: _selectedQualifications.toList(),
            preferredRoles: cleanPreferred,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Registration error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Volunteer Registration'),
        actions: [
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout),
            onPressed: _isLoading
                ? null
                : () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 580),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Verified Email Badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.brandGreen.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppTheme.brandGreen.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.verified,
                            color: AppTheme.brandGreen,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Verified Email: ${widget.verifiedEmail}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: AppTheme.brandGreen,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      'Personal Details',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      key: const Key('signup_name_input'),
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Full Name *',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (val) => val == null || val.trim().isEmpty
                          ? 'Please enter your full name'
                          : null,
                    ),
                    const SizedBox(height: 14),

                    TextFormField(
                      key: const Key('signup_phone_input'),
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number (Optional)',
                        hintText: '+44 7700 900000',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Qualifications & Role Preferences Section
                    RolePreferencesSelector(
                      title: 'Your Qualifications & Role Preferences',
                      qualifications: _selectedQualifications,
                      preferredRoles: _selectedPreferredRoles,
                      onQualificationChanged: (roleId, isQualified) {
                        setState(() {
                          if (isQualified) {
                            _selectedQualifications.add(roleId);
                          } else {
                            _selectedQualifications.remove(roleId);
                            _selectedPreferredRoles.remove(roleId);
                          }
                        });
                      },
                      onPreferredChanged: (roleId, isPreferred) {
                        setState(() {
                          if (isPreferred) {
                            _selectedQualifications.add(roleId);
                            _selectedPreferredRoles.add(roleId);
                          } else {
                            _selectedPreferredRoles.remove(roleId);
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 28),

                    // Contact Privacy Settings (Locked off for v1)
                    const Text(
                      'Contact Privacy Settings',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Contact details remain strictly private in this release and are never displayed on event rosters.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 12),

                    Card(
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: const Text(
                              'Public Phone Number',
                              style: TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text(
                              'Display phone number directly on rosters for calling/SMS',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _isPhonePublic,
                            onChanged: null,
                          ),
                          const Divider(height: 1),
                          SwitchListTile(
                            title: const Text(
                              'Public Email Address',
                              style: TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text(
                              'Display raw email address openly on rosters',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _isEmailPublic,
                            onChanged: null,
                          ),
                          const Divider(height: 1),
                          SwitchListTile(
                            title: const Text(
                              'Email Forwarding Address',
                              style: TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text(
                              'Generates a privacy alias (vol-xxxx@volunteer.roboref.app) that routes messages to your inbox without disclosing your personal address',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _forwardingEnabled,
                            onChanged: null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    ElevatedButton(
                      key: const Key('complete_onboarding_button'),
                      onPressed: _isLoading ? null : _submit,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Complete Registration & Get Started',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
