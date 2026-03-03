import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'user_access_service.dart';

class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});

  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _savingIds = <String>{};
  late final Future<bool> _isAdminFuture;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _isAdminFuture = _checkIsAdmin();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<bool> _checkIsAdmin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = snap.data();
      return data != null && data['isAdmin'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setUserActive({
    required String userId,
    required bool isActive,
  }) async {
    if (_savingIds.contains(userId)) return;
    setState(() => _savingIds.add(userId));
    try {
      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'isActive': isActive,
        'updatedAt': FieldValue.serverTimestamp(),
        if (isActive) 'activatedAt': FieldValue.serverTimestamp(),
        if (!isActive) 'deactivatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isActive
                ? 'Usuario activado correctamente.'
                : 'Usuario desactivado.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No se pudo actualizar: $e')));
    } finally {
      if (mounted) {
        setState(() => _savingIds.remove(userId));
      }
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '-';
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  Widget _buildUserRow(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final email = (data['email'] ?? '').toString().trim();
    final name = (data['displayName'] ?? '').toString().trim();
    final active = data['isActive'] == true;
    final isAdmin = data['isAdmin'] == true;
    final trialEndsAt = UserAccessService.readDate(data['trialEndsAt']);
    final trialActive =
        trialEndsAt != null && !DateTime.now().isAfter(trialEndsAt);
    final saving = _savingIds.contains(doc.id);

    final title = (name.isNotEmpty)
        ? name
        : (email.isNotEmpty ? email : doc.id);
    final subtitleParts = <String>[
      if (email.isNotEmpty && name.isNotEmpty) email,
      'UID: ${doc.id}',
      'Trial hasta: ${_formatDate(trialEndsAt)}',
      active
          ? 'Estado: Activo'
          : (trialActive ? 'Estado: Trial' : 'Estado: Vencido'),
      if (isAdmin) 'Rol: Admin',
    ];

    return Card(
      child: ListTile(
        title: Text(title),
        subtitle: Text(subtitleParts.join('\n')),
        isThreeLine: true,
        trailing: Switch(
          value: active,
          onChanged: saving
              ? null
              : (value) => _setUserActive(userId: doc.id, isActive: value),
        ),
      ),
    );
  }

  bool _matchesSearch(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    if (_search.isEmpty) return true;
    final q = _search.toLowerCase();
    final data = doc.data();
    final email = (data['email'] ?? '').toString().toLowerCase();
    final name = (data['displayName'] ?? '').toString().toLowerCase();
    final uid = doc.id.toLowerCase();
    return email.contains(q) || name.contains(q) || uid.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Panel admin - Usuarios')),
      body: FutureBuilder<bool>(
        future: _isAdminFuture,
        builder: (context, adminSnap) {
          if (adminSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (adminSnap.data != true) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No tenes permisos de administrador.\nPedi que te asignen isAdmin=true en users/{uid}.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Buscar por email, nombre o UID',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    setState(() => _search = value.trim());
                  },
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Error cargando usuarios: ${snap.error}'),
                        ),
                      );
                    }
                    final docs = (snap.data?.docs ?? const [])
                        .where(_matchesSearch)
                        .toList();

                    docs.sort((a, b) {
                      final da = UserAccessService.readDate(
                        a.data()['createdAt'],
                      );
                      final db = UserAccessService.readDate(
                        b.data()['createdAt'],
                      );
                      if (da == null && db == null) return a.id.compareTo(b.id);
                      if (da == null) return 1;
                      if (db == null) return -1;
                      return db.compareTo(da);
                    });

                    if (docs.isEmpty) {
                      return const Center(
                        child: Text('No hay usuarios para mostrar.'),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: docs.length,
                      itemBuilder: (context, index) =>
                          _buildUserRow(docs[index]),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
