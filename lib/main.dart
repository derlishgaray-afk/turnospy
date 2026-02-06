import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';
import 'auth_wrapper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const TurnosPYApp());
}

class TurnosPYApp extends StatelessWidget {
  const TurnosPYApp({super.key});

  Widget _buildApp({
    required ThemeMode themeMode,
    required Widget home,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      // ✅ Necesario para DatePicker / MaterialLocalizations
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('es', 'ES'),
        Locale('es', 'PY'),
        Locale('en', 'US'),
      ],
      locale: const Locale('es', 'ES'),

      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: themeMode,
      home: home,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return _buildApp(
            themeMode: ThemeMode.light,
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final user = authSnap.data;
        if (user == null) {
          return _buildApp(
            themeMode: ThemeMode.light,
            home: AuthWrapper(),
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
            ThemeMode mode = ThemeMode.light;
            if (settingsSnap.hasData && settingsSnap.data!.exists) {
              final data = settingsSnap.data!.data() as Map<String, dynamic>;
              final raw = (data['themeMode'] ?? 'light').toString();
              mode = raw == 'dark' ? ThemeMode.dark : ThemeMode.light;
            }
            return _buildApp(
              themeMode: mode,
              home: AuthWrapper(),
            );
          },
        );
      },
    );
  }
}
