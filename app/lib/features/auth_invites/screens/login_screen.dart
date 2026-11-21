import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../services/otp_auth_api_client.dart';
import '../state/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _inviteCodeController = TextEditingController();
  final _otpController = TextEditingController();

  AuthOtpMode _mode = AuthOtpMode.login;
  bool _awaitingOtp = false;
  bool _isBusy = false;
  bool _isGoogleBusy = false;
  String? _errorMessage;
  String? _infoMessage;
  int _resendSecondsRemaining = 0;
  Timer? _cooldownTimer;

  bool get _anyBusy => _isBusy || _isGoogleBusy;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    _inviteCodeController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    setState(() {
      _resendSecondsRemaining = seconds > 0 ? seconds : 0;
    });
    if (seconds <= 0) return;

    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSecondsRemaining <= 1) {
        timer.cancel();
        setState(() => _resendSecondsRemaining = 0);
      } else {
        setState(() => _resendSecondsRemaining -= 1);
      }
    });
  }

  Future<void> _continueWithGoogle() async {
    final inviteCode = _inviteCodeController.text.trim();
    if (_mode == AuthOtpMode.join && inviteCode.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your invitation code first.';
      });
      return;
    }

    setState(() {
      _isGoogleBusy = true;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final notifier = ref.read(authControllerProvider.notifier);
      if (_mode == AuthOtpMode.join) {
        await notifier.joinWithGoogle(inviteCode: inviteCode);
      } else {
        await notifier.signInWithGoogle();
      }
    } on AuthApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'google_signin_cancelled') {
        // User simply closed the Google account chooser; don't show an error banner.
        return;
      }
      if (e.code == 'invite_required') {
        setState(() {
          _mode = AuthOtpMode.join;
          _errorMessage = e.message;
        });
        return;
      }
      setState(() => _errorMessage = e.message);
    } catch (e, stack) {
      debugPrint('Google sign-in error: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Unable to complete Google sign-in right now. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isGoogleBusy = false);
      }
    }
  }

  Future<void> _requestOtp() async {
    final email = _emailController.text.trim();
    final inviteCode = _inviteCodeController.text.trim();

    if (_mode == AuthOtpMode.join && inviteCode.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your invitation code.';
      });
      return;
    }

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorMessage = 'Please enter a valid email address.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final notifier = ref.read(authControllerProvider.notifier);
      final result = _mode == AuthOtpMode.join
          ? await notifier.requestInviteOtp(
              email: email,
              inviteCode: inviteCode,
            )
          : await notifier.requestSignInOtp(email: email);

      if (!mounted) return;
      _otpController.clear();
      setState(() {
        _awaitingOtp = true;
        _infoMessage = result.message;
      });
      _startCooldown(result.cooldownSeconds);
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
      if (e.retryAfterSeconds != null && e.retryAfterSeconds! > 0) {
        _startCooldown(e.retryAfterSeconds!);
      }
    } catch (e, stack) {
      debugPrint('Error requesting OTP: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Unable to connect to authentication server. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailController.text.trim();
    final code = _otpController.text.trim();

    if (code.length != 6) {
      setState(() {
        _errorMessage =
            'Please enter the 6-digit verification code from your email.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authControllerProvider.notifier).verifyOtpAndSignIn(
            email: email,
            code: code,
          );
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (e, stack) {
      debugPrint('Error verifying OTP: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to verify code right now. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _resetToEmailStep() {
    _cooldownTimer?.cancel();
    setState(() {
      _awaitingOtp = false;
      _otpController.clear();
      _errorMessage = null;
      _infoMessage = null;
      _resendSecondsRemaining = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Brand Logo
                  Center(
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: AppTheme.brandGreen,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.brandGreen.withValues(alpha: 0.25),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.handshake_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  const Text(
                    'RoboVolunteers',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'VEX Robotics Competition Volunteer Management',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 28),

                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: AppTheme.brandGreen.withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: _awaitingOtp
                          ? _buildOtpVerificationStep()
                          : _buildEmailAndModeStep(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmailAndModeStep() {
    final isJoin = _mode == AuthOtpMode.join;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AuthOtpMode>(
          key: const Key('auth_mode_selector'),
          segments: const [
            ButtonSegment<AuthOtpMode>(
              value: AuthOtpMode.login,
              icon: Icon(Icons.login_rounded, size: 18),
              label: Text('Sign In'),
            ),
            ButtonSegment<AuthOtpMode>(
              value: AuthOtpMode.join,
              icon: Icon(Icons.vpn_key_outlined, size: 18),
              label: Text('New Volunteer'),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: _anyBusy
              ? null
              : (selection) {
                  setState(() {
                    _mode = selection.first;
                    _errorMessage = null;
                    _infoMessage = null;
                  });
                },
        ),
        const SizedBox(height: 20),

        Text(
          isJoin ? 'Join with Invitation Code' : 'Passwordless Volunteer Sign In',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          isJoin
              ? 'New volunteer registration is invite-only. Enter your invitation code first, then continue with Google or a 6-digit email code.'
              : 'Sign in with Google or receive a one-time 6-digit email code. Your session stays remembered on this device.',
          style: TextStyle(fontSize: 13, color: Colors.grey[700]),
        ),
        const SizedBox(height: 18),

        if (_errorMessage != null) ...[
          _buildBanner(
            message: _errorMessage!,
            isError: true,
          ),
          const SizedBox(height: 14),
        ],

        if (isJoin) ...[
          TextField(
            key: const Key('invite_code_input'),
            controller: _inviteCodeController,
            enabled: !_anyBusy,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Invitation Code',
              hintText: 'Enter your invite code',
              prefixIcon: Icon(Icons.pin_outlined),
            ),
          ),
          const SizedBox(height: 16),
        ],

        OutlinedButton.icon(
          key: const Key('google_signin_button'),
          onPressed: _anyBusy ? null : _continueWithGoogle,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
            side: BorderSide(color: Colors.grey.shade400),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: _isGoogleBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const _GoogleLogoBadge(),
          label: Text(
            _isGoogleBusy
                ? 'Connecting to Google...'
                : (isJoin
                    ? 'Verify Invite & Continue with Google'
                    : 'Continue with Google'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),

        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Divider(color: Colors.grey.shade300)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'OR USE EMAIL CODE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: Colors.grey[600],
                ),
              ),
            ),
            Expanded(child: Divider(color: Colors.grey.shade300)),
          ],
        ),
        const SizedBox(height: 16),

        TextField(
          key: const Key('login_email_input'),
          controller: _emailController,
          enabled: !_anyBusy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Email Address',
            hintText: 'name@example.co.uk',
            prefixIcon: Icon(Icons.email_outlined),
          ),
          onSubmitted: (_) => _requestOtp(),
        ),
        const SizedBox(height: 16),

        ElevatedButton.icon(
          key: const Key('request_otp_button'),
          onPressed: _anyBusy ? null : _requestOtp,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: _isBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.mark_email_read_outlined, size: 18),
          label: Text(
            _isBusy
                ? 'Sending Code...'
                : (isJoin
                    ? 'Verify Invite & Send 6-Digit Code'
                    : 'Send 6-Digit Sign-In Code'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildOtpVerificationStep() {
    final email = _emailController.text.trim().toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.mark_email_unread_outlined,
                color: AppTheme.brandGreen, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Enter 6-Digit Verification Code',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Sent to $email. Once verified, you will stay signed in on this device.',
          style: TextStyle(fontSize: 13, color: Colors.grey[700]),
        ),
        const SizedBox(height: 14),

        if (_infoMessage != null && _errorMessage == null) ...[
          _buildBanner(message: _infoMessage!, isError: false),
          const SizedBox(height: 14),
        ],

        if (_errorMessage != null) ...[
          _buildBanner(message: _errorMessage!, isError: true),
          const SizedBox(height: 14),
        ],

        TextField(
          key: const Key('otp_code_input'),
          controller: _otpController,
          enabled: !_anyBusy,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            letterSpacing: 10,
            fontFamily: 'monospace',
          ),
          decoration: const InputDecoration(
            labelText: '6-Digit Code',
            hintText: '000000',
            counterText: '',
            prefixIcon: Icon(Icons.password_rounded),
          ),
          onSubmitted: (_) => _verifyOtp(),
        ),
        const SizedBox(height: 18),

        ElevatedButton.icon(
          key: const Key('verify_otp_button'),
          onPressed: _anyBusy ? null : _verifyOtp,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: _isBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.verified_user_outlined, size: 18),
          label: Text(
            _isBusy ? 'Verifying...' : 'Verify Code & Sign In',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 12),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              key: const Key('change_email_button'),
              onPressed: _anyBusy ? null : _resetToEmailStep,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Change Email', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: const Key('resend_otp_button'),
              onPressed:
                  (_anyBusy || _resendSecondsRemaining > 0) ? null : _requestOtp,
              child: Text(
                _resendSecondsRemaining > 0
                    ? 'Resend in ${_resendSecondsRemaining}s'
                    : 'Resend Code',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBanner({required String message, required bool isError}) {
    final bgColor = isError ? Colors.red.shade50 : Colors.green.shade50;
    final borderColor = isError ? Colors.red.shade200 : Colors.green.shade200;
    final iconColor = isError ? Colors.red.shade700 : AppTheme.brandGreen;
    final textColor = isError ? Colors.red.shade900 : Colors.green.shade900;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: iconColor,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Self-contained Google "G" badge (avoids external network image requests).
class _GoogleLogoBadge extends StatelessWidget {
  const _GoogleLogoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: const Text(
        'G',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Color(0xFF4285F4),
          height: 1.0,
        ),
      ),
    );
  }
}
