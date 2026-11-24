import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_invites/services/otp_auth_api_client.dart';
import '../../auth_invites/state/auth_provider.dart';
import '../models/invite_code_model.dart';
import '../services/admin_invite_api_client.dart';

final adminInviteApiClientProvider = Provider<AdminInviteApiClient>((ref) {
  return AdminInviteApiClient();
});

class AdminInvitesController extends AsyncNotifier<List<InviteCodeModel>> {
  @override
  Future<List<InviteCodeModel>> build() async {
    final isAdmin = ref.watch(isAdminProvider);
    if (!isAdmin) {
      return const [];
    }
    return _fetchInvites();
  }

  Future<String> _requireIdToken() async {
    final token = await ref.read(authServiceProvider).getIdToken();
    if (token == null || token.trim().isEmpty) {
      throw const AuthApiException(
        code: 'unauthenticated',
        message: 'Your session has expired. Please sign in again.',
      );
    }
    return token;
  }

  Future<List<InviteCodeModel>> _fetchInvites() async {
    final token = await _requireIdToken();
    final api = ref.read(adminInviteApiClientProvider);
    return api.listInvites(idToken: token);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetchInvites);
  }

  Future<List<InviteCodeModel>> createInvites({
    String? label,
    int? expiresInDays,
    bool neverExpires = false,
    int count = 1,
  }) async {
    final token = await _requireIdToken();
    final api = ref.read(adminInviteApiClientProvider);
    final created = await api.createInvites(
      idToken: token,
      label: label,
      expiresInDays: expiresInDays,
      neverExpires: neverExpires,
      count: count,
    );

    if (ref.mounted) {
      final existing = state.asData?.value ?? const <InviteCodeModel>[];
      final createdIds = created.map((i) => i.id).toSet();
      final merged = <InviteCodeModel>[
        ...created,
        ...existing.where((item) => !createdIds.contains(item.id)),
      ];
      state = AsyncData(merged);
    }
    return created;
  }

  Future<InviteCodeModel> revokeInvite(String inviteId) async {
    final token = await _requireIdToken();
    final api = ref.read(adminInviteApiClientProvider);
    final revoked = await api.revokeInvite(
      idToken: token,
      inviteId: inviteId,
    );

    if (ref.mounted) {
      final existing = state.asData?.value ?? const <InviteCodeModel>[];
      final updated = [
        for (final item in existing)
          if (item.id == revoked.id) revoked else item,
      ];
      state = AsyncData(updated);
    }
    return revoked;
  }
}

final adminInvitesControllerProvider =
    AsyncNotifierProvider<AdminInvitesController, List<InviteCodeModel>>(
  AdminInvitesController.new,
);
