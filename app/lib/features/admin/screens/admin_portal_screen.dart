import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/invite_link_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../auth_invites/services/otp_auth_api_client.dart';
import '../../auth_invites/state/auth_provider.dart';
import '../models/invite_code_model.dart';
import '../state/admin_invites_provider.dart';

enum _InviteFilter {
  all('All'),
  active('Active'),
  used('Used'),
  inactive('Revoked / Expired');

  final String label;
  const _InviteFilter(this.label);
}

class AdminPortalScreen extends ConsumerStatefulWidget {
  const AdminPortalScreen({super.key});

  @override
  ConsumerState<AdminPortalScreen> createState() => _AdminPortalScreenState();
}

class _AdminPortalScreenState extends ConsumerState<AdminPortalScreen> {
  final _labelController = TextEditingController();
  final _searchController = TextEditingController();

  int? _expiresInDays = 30; // null means Never expires
  int _quantity = 1;
  bool _isGenerating = false;
  final Set<String> _revokingIds = {};
  List<InviteCodeModel> _recentlyGenerated = const [];
  _InviteFilter _filter = _InviteFilter.all;
  String _searchQuery = '';
  String? _actionError;

  static const List<int?> _expiryOptions = [7, 30, 90, null];
  static const List<int> _quantityOptions = [1, 2, 3, 5, 10, 20];

  @override
  void dispose() {
    _labelController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _resolveInviteUrl(InviteCodeModel invite) {
    final webOrigin = kIsWeb ? InviteLinkUtils.resolveAppBaseUrl() : null;
    return invite.resolveInviteUrl(appBaseUrl: webOrigin) ??
        InviteLinkUtils.buildInviteUrl(invite.displayCode);
  }

  Future<void> _copyText(String text, String confirmation) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(confirmation),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareViaEmail(InviteCodeModel invite) async {
    if (!invite.isActive || invite.code == null) return;
    final url = _resolveInviteUrl(invite);
    final body = InviteLinkUtils.buildShareMessage(
      inviteUrl: url,
      inviteCode: invite.code!,
      recipientLabel: invite.label,
    );
    final launched = await UrlUtils.openEmail(
      recipientEmail: '',
      subject: "You're invited to RoboVolunteers",
      body: body,
    );
    if (!launched && mounted) {
      await _copyText(
        body,
        'Could not open email client — invite message copied to clipboard instead.',
      );
    }
  }

  Future<void> _generateInvites() async {
    setState(() {
      _isGenerating = true;
      _actionError = null;
    });

    try {
      final created = await ref
          .read(adminInvitesControllerProvider.notifier)
          .createInvites(
            label: _labelController.text.trim().isNotEmpty
                ? _labelController.text.trim()
                : null,
            expiresInDays: _expiresInDays,
            neverExpires: _expiresInDays == null,
            count: _quantity,
          );
      if (!mounted) return;
      _labelController.clear();
      setState(() {
        _recentlyGenerated = created;
        _quantity = 1;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created.length == 1
                ? 'One-time invite link generated!'
                : '${created.length} one-time invite links generated!',
          ),
        ),
      );
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _actionError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = 'Unable to generate invite code: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _confirmAndRevoke(InviteCodeModel invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Invitation Code?'),
        content: Text(
          'Revoking ${invite.displayCode}${invite.label != null ? ' (${invite.label})' : ''} immediately invalidates its invite link. Anyone who has not yet registered with it will need a new code.',
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
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _revokingIds.add(invite.id);
      _actionError = null;
    });

    try {
      await ref
          .read(adminInvitesControllerProvider.notifier)
          .revokeInvite(invite.id);
      if (!mounted) return;
      setState(() {
        _recentlyGenerated = _recentlyGenerated
            .where((item) => item.id != invite.id)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invitation code revoked.')),
      );
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _actionError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = 'Unable to revoke invite code: $e');
    } finally {
      if (mounted) {
        setState(() => _revokingIds.remove(invite.id));
      }
    }
  }

  List<InviteCodeModel> _applyFilters(List<InviteCodeModel> all) {
    final query = _searchQuery.trim().toLowerCase();
    return all.where((item) {
      switch (_filter) {
        case _InviteFilter.all:
          break;
        case _InviteFilter.active:
          if (!item.isActive) return false;
          break;
        case _InviteFilter.used:
          if (!item.isUsed) return false;
          break;
        case _InviteFilter.inactive:
          if (!item.isRevoked && !item.isExpired) return false;
          break;
      }

      if (query.isEmpty) return true;
      return item.displayCode.toLowerCase().contains(query) ||
          (item.label?.toLowerCase().contains(query) ?? false) ||
          item.createdByEmail.toLowerCase().contains(query) ||
          (item.usedByEmail?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('d MMM y, HH:mm').format(dt.toLocal());
  }

  String _formatDate(DateTime dt) {
    return DateFormat('d MMM y').format(dt.toLocal());
  }

  String _expiryOptionLabel(int? days) {
    if (days == null) return 'Never';
    return '$days days';
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin Portal')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: const Padding(
              padding: EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline, size: 48, color: Colors.orange),
                      SizedBox(height: 16),
                      Text(
                        'Administrator Access Required',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Only manually authorized administrators can generate or manage volunteer invitation codes.',
                        textAlign: TextAlign.center,
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

    final invitesAsync = ref.watch(adminInvitesControllerProvider);
    final allInvites = invitesAsync.asData?.value ?? const <InviteCodeModel>[];
    final activeCount = allInvites.where((i) => i.isActive).length;
    final usedCount = allInvites.where((i) => i.isUsed).length;
    final inactiveCount =
        allInvites.where((i) => i.isRevoked || i.isExpired).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Portal'),
        actions: [
          IconButton(
            key: const Key('admin_refresh_invites_button'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Invites',
            onPressed: () =>
                ref.read(adminInvitesControllerProvider.notifier).refresh(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(adminInvitesControllerProvider.notifier).refresh(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeaderSummaryCard(
                    activeCount: activeCount,
                    usedCount: usedCount,
                    inactiveCount: inactiveCount,
                  ),
                  const SizedBox(height: 16),
                  if (_actionError != null) ...[
                    _buildErrorBanner(_actionError!),
                    const SizedBox(height: 16),
                  ],
                  _buildGeneratorCard(),
                  if (_recentlyGenerated.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildRecentlyGeneratedCard(),
                  ],
                  const SizedBox(height: 24),
                  _buildInvitesListSection(invitesAsync),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderSummaryCard({
    required int activeCount,
    required int usedCount,
    required int inactiveCount,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.admin_panel_settings_outlined,
                  color: AppTheme.brandGreen,
                  size: 24,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Volunteer Invitations',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Generate single-use invitation codes and shareable hyperlinks to onboard new volunteers. Each code can only be redeemed once.',
              style: TextStyle(fontSize: 13, color: Colors.grey[700]),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _StatPill(
                  label: 'Active',
                  count: activeCount,
                  color: AppTheme.statusConfirmed,
                ),
                _StatPill(
                  label: 'Used',
                  count: usedCount,
                  color: AppTheme.statusAvailable,
                ),
                _StatPill(
                  label: 'Revoked / Expired',
                  count: inactiveCount,
                  color: Colors.grey.shade700,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: Colors.red.shade900,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _actionError = null),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildGeneratorCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Generate One-Time Invite',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_invite_label_input'),
              controller: _labelController,
              enabled: !_isGenerating,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Recipient Name or Note (Optional)',
                hintText: 'e.g. Jane Doe – Head Referee',
                prefixIcon: Icon(Icons.person_add_alt_1_outlined),
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Expires After',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: _expiryOptions.map((days) {
                        final selected = _expiresInDays == days;
                        return ChoiceChip(
                          label: Text(_expiryOptionLabel(days)),
                          selected: selected,
                          onSelected: _isGenerating
                              ? null
                              : (_) => setState(() => _expiresInDays = days),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quantity',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButton<int>(
                      key: const Key('admin_invite_count_dropdown'),
                      value: _quantity,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(10),
                      items: _quantityOptions
                          .map(
                            (count) => DropdownMenuItem<int>(
                              value: count,
                              child: Text(
                                count == 1 ? '1 invite' : '$count invites',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _isGenerating
                          ? null
                          : (val) {
                              if (val != null) {
                                setState(() => _quantity = val);
                              }
                            },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              key: const Key('admin_generate_invite_button'),
              onPressed: _isGenerating ? null : _generateInvites,
              icon: _isGenerating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_link_rounded, size: 20),
              label: Text(
                _isGenerating
                    ? 'Generating...'
                    : (_quantity == 1
                        ? 'Generate One-Time Invite Link'
                        : 'Generate $_quantity One-Time Invite Links'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentlyGeneratedCard() {
    final isBatch = _recentlyGenerated.length > 1;
    final allLinks = _recentlyGenerated.map(_resolveInviteUrl).join('\n');

    return Card(
      key: const Key('recently_generated_invites_card'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppTheme.brandGreen.withValues(alpha: 0.45),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  color: AppTheme.brandGreen,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isBatch
                        ? '${_recentlyGenerated.length} Invite Links Ready to Share'
                        : 'Invite Link Ready to Share',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.brandGreen,
                    ),
                  ),
                ),
                if (isBatch)
                  TextButton.icon(
                    key: const Key('copy_all_generated_links_button'),
                    onPressed: () => _copyText(
                      allLinks,
                      'All ${_recentlyGenerated.length} invite links copied to clipboard.',
                    ),
                    icon: const Icon(Icons.copy_all, size: 18),
                    label: const Text('Copy All'),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _recentlyGenerated = const []),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ..._recentlyGenerated.map((invite) {
              final url = _resolveInviteUrl(invite);
              final code = invite.code ?? invite.displayCode;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.brandGreen.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.brandGreen.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (invite.label != null) ...[
                      Text(
                        invite.label!,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    SelectableText(
                      url,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Code: $code',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          key: Key('copy_generated_link_${invite.id}'),
                          onPressed: () => _copyText(
                            url,
                            'Invite link copied to clipboard.',
                          ),
                          icon: const Icon(Icons.link, size: 16),
                          label: const Text('Copy Link'),
                        ),
                        OutlinedButton.icon(
                          key: Key('copy_generated_message_${invite.id}'),
                          onPressed: () => _copyText(
                            InviteLinkUtils.buildShareMessage(
                              inviteUrl: url,
                              inviteCode: code,
                              recipientLabel: invite.label,
                            ),
                            'Invite message copied to clipboard.',
                          ),
                          icon: const Icon(Icons.message_outlined, size: 16),
                          label: const Text('Copy Message'),
                        ),
                        OutlinedButton.icon(
                          key: Key('copy_generated_code_${invite.id}'),
                          onPressed: () => _copyText(
                            code,
                            'Invite code copied to clipboard.',
                          ),
                          icon: const Icon(Icons.vpn_key_outlined, size: 16),
                          label: const Text('Copy Code'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _shareViaEmail(invite),
                          icon: const Icon(Icons.email_outlined, size: 16),
                          label: const Text('Email'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildInvitesListSection(AsyncValue<List<InviteCodeModel>> invitesAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Issued Invitations',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('admin_invite_search_input'),
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search by note, code, or email...',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  )
                : null,
          ),
          onChanged: (val) => setState(() => _searchQuery = val),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _InviteFilter.values.map((filter) {
              final selected = _filter == filter;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(filter.label),
                  selected: selected,
                  selectedColor: AppTheme.brandGreen.withValues(alpha: 0.15),
                  checkmarkColor: AppTheme.brandGreen,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        invitesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (err, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 40),
                  const SizedBox(height: 10),
                  Text(
                    err.toString(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => ref
                        .read(adminInvitesControllerProvider.notifier)
                        .refresh(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
          data: (allInvites) {
            final filtered = _applyFilters(allInvites);
            if (filtered.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 32,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.vpn_key_off_outlined,
                        size: 40,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        allInvites.isEmpty
                            ? 'No one-time invite codes generated yet.'
                            : 'No invite codes match your current filter.',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }

            return Column(
              children: filtered
                  .map((invite) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _buildInviteCard(invite),
                      ))
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildInviteCard(InviteCodeModel invite) {
    final isRevoking = _revokingIds.contains(invite.id);
    final statusColor = switch (invite.status) {
      InviteCodeStatus.active => AppTheme.statusConfirmed,
      InviteCodeStatus.used => AppTheme.statusAvailable,
      InviteCodeStatus.revoked => Colors.red.shade700,
      InviteCodeStatus.expired => Colors.orange.shade800,
    };
    final activeUrl = invite.isActive ? _resolveInviteUrl(invite) : null;

    return Card(
      key: Key('invite_card_${invite.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    invite.status.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    invite.displayCode,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (invite.label != null) ...[
              const SizedBox(height: 6),
              Text(
                invite.label!,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (activeUrl != null) ...[
              const SizedBox(height: 6),
              SelectableText(
                activeUrl,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.grey[700],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Created ${_formatDateTime(invite.createdAt)} by ${invite.createdByEmail}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            if (invite.expiresAt != null && !invite.isUsed) ...[
              const SizedBox(height: 2),
              Text(
                invite.isExpired
                    ? 'Expired ${_formatDate(invite.expiresAt!)}'
                    : 'Expires ${_formatDate(invite.expiresAt!)}',
                style: TextStyle(
                  fontSize: 12,
                  color: invite.isExpired
                      ? Colors.orange.shade800
                      : Colors.grey[600],
                ),
              ),
            ],
            if (invite.isUsed && invite.usedAt != null) ...[
              const SizedBox(height: 2),
              Text(
                'Redeemed ${_formatDateTime(invite.usedAt!)}${invite.usedByEmail != null ? ' by ${invite.usedByEmail}' : ''}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.statusAvailable,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (invite.isRevoked && invite.revokedAt != null) ...[
              const SizedBox(height: 2),
              Text(
                'Revoked ${_formatDateTime(invite.revokedAt!)}${invite.revokedByEmail != null ? ' by ${invite.revokedByEmail}' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (invite.isActive && activeUrl != null && invite.code != null) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  OutlinedButton.icon(
                    key: Key('copy_link_${invite.id}'),
                    onPressed: () => _copyText(
                      activeUrl,
                      'Invite link copied to clipboard.',
                    ),
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('Copy Link'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: Key('copy_message_${invite.id}'),
                    onPressed: () => _copyText(
                      InviteLinkUtils.buildShareMessage(
                        inviteUrl: activeUrl,
                        inviteCode: invite.code!,
                        recipientLabel: invite.label,
                      ),
                      'Invite message copied to clipboard.',
                    ),
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('Copy Message'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _shareViaEmail(invite),
                    icon: const Icon(Icons.email_outlined, size: 16),
                    label: const Text('Email'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  TextButton.icon(
                    key: Key('revoke_invite_${invite.id}'),
                    onPressed: isRevoking
                        ? null
                        : () => _confirmAndRevoke(invite),
                    icon: isRevoking
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.block,
                            size: 16,
                            color: Colors.red.shade700,
                          ),
                    label: Text(
                      isRevoking ? 'Revoking...' : 'Revoke',
                      style: TextStyle(color: Colors.red.shade700),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatPill({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: color,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
