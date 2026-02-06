import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'login_page.dart';
import 'home_page.dart';
import 'settings_setup_page.dart';

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

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
        if (user == null) return LoginPage();

        final userDocRef = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid);

        return StreamBuilder<DocumentSnapshot>(
          stream: userDocRef.snapshots(),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (!userSnap.hasData || !userSnap.data!.exists) {
              return const AccessBlockedPage(
                message:
                    'Tu cuenta aún no fue habilitada. Contactá al administrador.',
              );
            }

            final data = userSnap.data!.data() as Map<String, dynamic>;
            final active = data['isActive'] == true;

            if (!active) {
              return const AccessBlockedPage(
                message:
                    'Tu suscripción está vencida o la cuenta fue deshabilitada.',
              );
            }

            final settingsRef = FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .collection('settings')
                .doc('default');

            return StreamBuilder<DocumentSnapshot>(
              stream: settingsRef.snapshots(),
              builder: (context, settingsSnap) {
                if (settingsSnap.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                // Si no existe settings/default => mostrar setup
                if (!settingsSnap.hasData || !settingsSnap.data!.exists) {
                  return const SettingsSetupPage();
                }

                // Si existe => entrar
                return HomePage();
              },
            );
          },
        );
      },
    );
  }
}

class AccessBlockedPage extends StatelessWidget {
  final String message;
  const AccessBlockedPage({super.key, required this.message});

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
              ElevatedButton(
                onPressed: () => FirebaseAuth.instance.signOut(),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
