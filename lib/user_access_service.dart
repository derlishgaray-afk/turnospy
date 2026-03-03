import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserAccessService {
  static const int trialDays = 5;
  static const String activationWhatsappE164 = '+595986872691';
  static const String activationWhatsappDigits = '595986872691';

  static DocumentReference<Map<String, dynamic>> _userRef(String uid) {
    return FirebaseFirestore.instance.collection('users').doc(uid);
  }

  static Future<void> ensureUserAccessDocument(User user) async {
    try {
      final userRef = _userRef(user.uid);
      final userSnap = await userRef.get();
      final now = DateTime.now();
      final trialEnd = now.add(const Duration(days: trialDays));

      if (!userSnap.exists) {
        await userRef.set({
          'email': user.email,
          'displayName': user.displayName,
          'isActive': false,
          'trialStartedAt': Timestamp.fromDate(now),
          'trialEndsAt': Timestamp.fromDate(trialEnd),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }

      final data = userSnap.data() ?? <String, dynamic>{};
      final updates = <String, dynamic>{};

      if (data['trialStartedAt'] == null || data['trialEndsAt'] == null) {
        updates['trialStartedAt'] = Timestamp.fromDate(now);
        updates['trialEndsAt'] = Timestamp.fromDate(trialEnd);
      }
      if ((data['email'] == null || data['email'].toString().isEmpty) &&
          user.email != null) {
        updates['email'] = user.email;
      }
      if ((data['displayName'] == null ||
              data['displayName'].toString().isEmpty) &&
          user.displayName != null &&
          user.displayName!.trim().isNotEmpty) {
        updates['displayName'] = user.displayName!.trim();
      }

      if (updates.isNotEmpty) {
        updates['updatedAt'] = FieldValue.serverTimestamp();
        await userRef.set(updates, SetOptions(merge: true));
      }
    } on FirebaseException catch (e) {
      // No bloquear login/acceso por reglas de Firestore.
      if (e.code == 'permission-denied') return;
      rethrow;
    }
  }

  static DateTime? readDate(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static String activationMessageForUser(User user) {
    final identity = (user.email != null && user.email!.trim().isNotEmpty)
        ? user.email!.trim()
        : user.uid;
    return 'Hola, mi prueba gratis de TurnosPY termino y quiero activar mi cuenta. Usuario: $identity';
  }

  static DateTime? authCreatedAt(User user) {
    final raw = user.metadata.creationTime;
    if (raw == null) return null;
    return DateTime(
      raw.year,
      raw.month,
      raw.day,
      raw.hour,
      raw.minute,
      raw.second,
    );
  }

  static DateTime? authTrialEndsAt(User user) {
    final createdAt = authCreatedAt(user);
    if (createdAt == null) return null;
    return createdAt.add(const Duration(days: trialDays));
  }
}
