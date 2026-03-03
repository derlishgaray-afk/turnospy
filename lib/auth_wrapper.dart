import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home_page.dart';
import 'login_page.dart';
import 'settings_setup_page.dart';
import 'user_guide_page.dart';
import 'user_access_service.dart';

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  String? _lastEnsureUid;
  final Set<String> _pendingGuideUids = <String>{};
  final Set<String> _guideShownUids = <String>{};

  void _kickoffEnsureUserAccess(User user) {
    if (_lastEnsureUid == user.uid) return;
    _lastEnsureUid = user.uid;
    unawaited(UserAccessService.ensureUserAccessDocument(user));
  }

  bool _trialStillActive(DateTime? trialEndsAt) {
    if (trialEndsAt == null) return false;
    return !DateTime.now().isAfter(trialEndsAt);
  }

  String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  bool _isPermissionDenied(Object? error) {
    if (error is FirebaseException) {
      return error.code == 'permission-denied';
    }
    return false;
  }

  Widget _buildRulesBlockedPage() {
    return const AccessBlockedPage(
      message:
          'No hay permisos en Firestore para este usuario.\nConfigura las reglas para que cada usuario pueda leer/escribir en users/{uid} y sus subcolecciones.',
    );
  }

  Widget _buildExpiredAccess(DateTime? trialEndsAt) {
    final expirationLine = (trialEndsAt == null)
        ? 'Tu prueba gratis ya finalizo.'
        : 'Tu prueba gratis finalizo el ${_formatDate(trialEndsAt)}.';
    return AccessBlockedPage(
      message:
          '$expirationLine\nPara continuar, solicita activacion al WhatsApp ${UserAccessService.activationWhatsappE164}.',
      showActivationButton: true,
    );
  }

  Widget _buildSettingsGate(User user) {
    final settingsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('default');

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: settingsRef.snapshots(),
      builder: (context, settingsSnap) {
        if (settingsSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (settingsSnap.hasError) {
          if (_isPermissionDenied(settingsSnap.error)) {
            return _buildRulesBlockedPage();
          }
          return const AccessBlockedPage(
            message:
                'No se pudo cargar tu configuracion. Cierra sesion e intenta nuevamente.',
          );
        }

        if (!settingsSnap.hasData || !settingsSnap.data!.exists) {
          _pendingGuideUids.add(user.uid);
          return const SettingsSetupPage();
        }

        final shouldOpenGuideNow =
            _pendingGuideUids.remove(user.uid) &&
            !_guideShownUids.contains(user.uid);
        if (shouldOpenGuideNow) {
          _guideShownUids.add(user.uid);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const UserGuidePage()));
          });
        }

        return const HomePage();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = authSnap.data;
        if (user == null) {
          _lastEnsureUid = null;
          _pendingGuideUids.clear();
          _guideShownUids.clear();
          return const LoginPage();
        }

        _kickoffEnsureUserAccess(user);

        final userDocRef = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid);

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: userDocRef.snapshots(),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (userSnap.hasError) {
              if (_isPermissionDenied(userSnap.error)) {
                return _buildRulesBlockedPage();
              }
              final trialEndsAt = UserAccessService.authTrialEndsAt(user);
              if (_trialStillActive(trialEndsAt)) {
                return _buildSettingsGate(user);
              }
              return _buildExpiredAccess(trialEndsAt);
            }

            final userDoc = userSnap.data;
            if (userDoc == null || !userDoc.exists) {
              final trialEndsAt = UserAccessService.authTrialEndsAt(user);
              if (_trialStillActive(trialEndsAt)) {
                return _buildSettingsGate(user);
              }
              return _buildExpiredAccess(trialEndsAt);
            }

            final data = userDoc.data() ?? <String, dynamic>{};
            final active = data['isActive'] == true;
            final trialEndsAt =
                UserAccessService.readDate(data['trialEndsAt']) ??
                UserAccessService.authTrialEndsAt(user);

            if (!active && !_trialStillActive(trialEndsAt)) {
              return _buildExpiredAccess(trialEndsAt);
            }

            return _buildSettingsGate(user);
          },
        );
      },
    );
  }
}

class AccessBlockedPage extends StatelessWidget {
  final String message;
  final bool showActivationButton;

  const AccessBlockedPage({
    super.key,
    required this.message,
    this.showActivationButton = false,
  });

  Future<void> _openActivationWhatsapp(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    final msg = user != null
        ? UserAccessService.activationMessageForUser(user)
        : 'Hola, quiero activar mi cuenta de TurnosPY.';
    final encoded = Uri.encodeComponent(msg);

    final webUri = Uri.parse(
      'https://wa.me/${UserAccessService.activationWhatsappDigits}?text=$encoded',
    );
    final appUri = Uri.parse(
      'whatsapp://send?phone=${UserAccessService.activationWhatsappDigits}&text=$encoded',
    );

    final launchedWeb = await launchUrl(
      webUri,
      mode: LaunchMode.externalApplication,
    );

    if (launchedWeb) return;

    final launchedApp = await launchUrl(
      appUri,
      mode: LaunchMode.externalApplication,
    );

    if (!launchedApp && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Acceso restringido')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (showActivationButton) ...[
                FilledButton.icon(
                  onPressed: () => _openActivationWhatsapp(context),
                  icon: const Icon(Icons.message_outlined),
                  label: const Text('Solicitar activacion por WhatsApp'),
                ),
                const SizedBox(height: 8),
              ],
              ElevatedButton(
                onPressed: () => FirebaseAuth.instance.signOut(),
                child: const Text('Cerrar sesion'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
