import 'package:flutter_test/flutter_test.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';
import 'package:robovolunteers/features/volunteering/models/signup_model.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';

void main() {
  group('My Volunteer Data & Signups Tests', () {
    late VolunteerRepository repository;

    setUp(() {
      repository = VolunteerRepository(InMemorySignupStore());
    });

    test('Production store starts clean with zero pre-seeded fake signups',
        () async {
      final signups =
          await repository.getSignupsForEvent('RE-V5RC-26-9102');
      expect(signups, isEmpty);
    });

    test('Saving new signup for volunteer updates their personal signups list',
        () async {
      const volunteer = VolunteerModel(
        id: 'vol-user-123',
        name: 'Test Volunteer',
        email: 'test@example.co.uk',
        qualifications: ['ref', 'judge'],
        forwardingAddress: 'vol-test1234@volunteer.roboref.app',
      );

      var userSignups = await repository.getSignupsForVolunteer(volunteer.id);
      expect(userSignups, isEmpty);

      await repository.saveSignup(
        sku: 'RE-VIQRC-26-8821',
        volunteer: volunteer,
        status: SignupStatus.confirmed,
        offeredRoles: ['ref'],
        notes: 'Available for morning matches',
      );

      userSignups = await repository.getSignupsForVolunteer(volunteer.id);
      expect(userSignups.length, equals(1));
      expect(userSignups.first.sku, equals('RE-VIQRC-26-8821'));
      expect(userSignups.first.status, equals(SignupStatus.confirmed));
      expect(userSignups.first.epVerified, isFalse);
      expect(userSignups.first.notes, equals('Available for morning matches'));

      final withdrawn = await repository.withdrawSignup(
        sku: 'RE-VIQRC-26-8821',
        volunteerId: volunteer.id,
      );
      expect(withdrawn, isTrue);

      userSignups = await repository.getSignupsForVolunteer(volunteer.id);
      expect(userSignups, isEmpty);
    });

    test('Firestore profile deserialization keeps all privacy & EP flags off',
        () {
      final restored = VolunteerModel.fromFirestoreMaps(
        uid: 'vol-legacy',
        publicData: const {
          'id': 'vol-legacy',
          'name': 'Legacy Volunteer',
          'qualifications': ['ref'],
          'forwardingAddress': 'vol-legacy01@volunteer.roboref.app',
          'isEmailPublic': true,
          'isPhonePublic': true,
          'forwardingEnabled': true,
          'isEventPartner': true,
        },
        privateData: const {
          'email': 'legacy@example.org',
          'phone': '+44 7700 900111',
        },
      );

      expect(restored.email, equals('legacy@example.org'));
      expect(restored.phone, equals('+44 7700 900111'));
      expect(restored.isEmailPublic, isFalse);
      expect(restored.isPhonePublic, isFalse);
      expect(restored.forwardingEnabled, isFalse);
      expect(restored.isEventPartner, isFalse);
    });
  });
}
