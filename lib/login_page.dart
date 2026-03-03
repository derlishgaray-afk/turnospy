import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'user_access_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _loading = false;
  String? _error;

  String _mapAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'operation-not-allowed':
        return 'Este metodo no esta habilitado en Firebase Auth.';
      case 'popup-closed-by-user':
        return 'Se cancelo el inicio de sesion.';
      case 'user-disabled':
        return 'Esta cuenta fue deshabilitada.';
      default:
        return e.message ?? e.code;
    }
  }

  Future<void> _signInWithProvider(AuthProvider provider) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final auth = FirebaseAuth.instance;
      final cred = kIsWeb
          ? await auth.signInWithPopup(provider)
          : await auth.signInWithProvider(provider);

      if (cred.user != null) {
        try {
          await UserAccessService.ensureUserAccessDocument(cred.user!);
        } catch (_) {
          // El acceso se resolvera con fallback en AuthWrapper.
        }
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _mapAuthError(e));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    final provider = GoogleAuthProvider();
    provider.addScope('email');
    await _signInWithProvider(provider);
  }

  Future<void> _signInWithApple() async {
    final provider = AppleAuthProvider();
    provider.addScope('email');
    provider.addScope('name');
    await _signInWithProvider(provider);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TurnosPY - Iniciar sesion')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Inicia sesion con Google o Apple. Si no tenes cuenta, se crea automaticamente.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Si ya te registraste, usa el mismo proveedor para ingresar.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _signInWithGoogle,
                    icon: const Icon(Icons.g_mobiledata),
                    label: const Text('Ingresar con Google'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _signInWithApple,
                    icon: const Icon(Icons.apple),
                    label: const Text('Ingresar con Apple'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Al terminar los 5 dias de prueba, solicita activacion al WhatsApp +595986872691.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
