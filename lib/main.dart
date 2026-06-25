import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Firebase initialized: ${Firebase.app().options.projectId}');
  } on Object catch (error, stackTrace) {
    debugPrint('Firebase initialize error: $error');
    debugPrintStack(stackTrace: stackTrace);
    // The app can still run with phone-local storage until Firebase config is added.
  }

  runApp(const PasswordManagerApp());
}

class PasswordManagerApp extends StatelessWidget {
  const PasswordManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CipherVault',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
          surface: const Color(0xFFF9FAFB),
        ),
        textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF9FAFB),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          iconTheme: IconThemeData(color: Color(0xFF111827)),
          titleTextStyle: TextStyle(
            color: Color(0xFF111827),
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 2,
          shadowColor: Colors.black.withOpacity(0.05),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.shade100, width: 1),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade200),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade200),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2),
          ),
          hintStyle: TextStyle(color: Colors.grey.shade400),
        ),
      ),
      home: const PasswordManagerScreen(),
    );
  }
}

class Credential {
  Credential({
    required this.id,
    required this.platform,
    required this.username,
    required this.encryptedPassword,
    required this.category,
    this.link = '',
  });

  final int id;
  final String platform;
  final String username;
  final String encryptedPassword;
  final String category;
  final String link;

  factory Credential.fromJson(Map<String, dynamic> json) {
    return Credential(
      id: json['id'] as int,
      platform: (json['platform'] ?? json['account'] ?? 'Unknown') as String,
      username: json['username'] as String,
      encryptedPassword: json['encryptedPassword'] as String,
      category: json['category'] as String,
      link: json['link'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'platform': platform,
      'username': username,
      'encryptedPassword': encryptedPassword,
      'category': category,
      'link': link,
    };
  }

  Credential copyWith({
    String? platform,
    String? username,
    String? encryptedPassword,
    String? category,
    String? link,
  }) {
    return Credential(
      id: id,
      platform: platform ?? this.platform,
      username: username ?? this.username,
      encryptedPassword: encryptedPassword ?? this.encryptedPassword,
      category: category ?? this.category,
      link: link ?? this.link,
    );
  }
}

class SavedVault {
  const SavedVault({required this.credentials, required this.nextId});

  final List<Credential> credentials;
  final int nextId;
}

class CredentialStorage {
  /// Returns the vault ID: the Firebase Auth UID when signed in,
  /// otherwise a web fallback or device-unique ID.
  String _vaultId() {
    if (Firebase.apps.isNotEmpty) {
      try {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) return uid;
      } catch (_) {
        // Fallback if FirebaseAuth fails to initialize
      }
    }
    if (kIsWeb) return 'default_test_vault';
    // Fallback: should not happen if auth is required before loading.
    return 'vault_anonymous';
  }

  String get _credentialsKey => 'cipher_vault_credentials_${_vaultId()}';
  String get _nextIdKey => 'cipher_vault_next_id_${_vaultId()}';

  Future<void> clearLocal() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_credentialsKey);
    await preferences.remove(_nextIdKey);
    // Legacy global keys cleanup
    await preferences.remove('cipher_vault_credentials');
    await preferences.remove('cipher_vault_next_id');
  }

  Future<SavedVault> load() async {
    final localVault = await _loadLocal();

    if (Firebase.apps.isEmpty) {
      debugPrint('Firebase not initialized. Loading phone-local vault only.');
      return localVault;
    }

    try {
      final vaultId = _vaultId();
      final snapshot = await FirebaseFirestore.instance
          .collection('passwordVaults')
          .doc(vaultId)
          .get()
          .timeout(const Duration(seconds: 10));

      if (!snapshot.exists) {
        await save(localVault.credentials, localVault.nextId);
        debugPrint('Firestore vault did not exist. Created a new vault.');
        return localVault;
      }

      final data = snapshot.data()!;
      final savedCredentials = data['credentials'] as List<dynamic>? ?? [];
      final credentials = savedCredentials
          .map((item) => Credential.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      final nextId = data['nextId'] as int? ?? _nextIdAfter(credentials);
      final savedVault = SavedVault(credentials: credentials, nextId: nextId);

      await _saveLocal(credentials, nextId);
      debugPrint('Loaded ${credentials.length} credentials from Firestore.');
      return savedVault;
    } on Object catch (error, stackTrace) {
      debugPrint('Firestore load error: $error');
      debugPrintStack(stackTrace: stackTrace);
      return localVault;
    }
  }

  Future<void> save(List<Credential> credentials, int nextId) async {
    await _saveLocal(credentials, nextId);

    if (Firebase.apps.isEmpty) {
      debugPrint('Firestore save skipped. Firebase is not initialized.');
      return;
    }

    try {
      final vaultId = _vaultId();

      await FirebaseFirestore.instance
          .collection('passwordVaults')
          .doc(vaultId)
          .set({
            'credentials': credentials
                .map((credential) => credential.toJson())
                .toList(),
            'nextId': nextId,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(const Duration(seconds: 10));
      debugPrint('Saved ${credentials.length} credentials to Firestore.');
    } on Object catch (error, stackTrace) {
      debugPrint('Firestore save error: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<SavedVault> _loadLocal() async {
    final preferences = await SharedPreferences.getInstance();
    final savedCredentials = preferences.getString(_credentialsKey);

    if (savedCredentials == null) {
      return const SavedVault(credentials: <Credential>[], nextId: 1);
    }

    final decoded = jsonDecode(savedCredentials) as List<dynamic>;
    final credentials = decoded
        .map((item) => Credential.fromJson(item as Map<String, dynamic>))
        .toList();
    final nextId = preferences.getInt(_nextIdKey) ?? _nextIdAfter(credentials);

    return SavedVault(credentials: credentials, nextId: nextId);
  }

  Future<void> _saveLocal(List<Credential> credentials, int nextId) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      credentials.map((credential) => credential.toJson()).toList(),
    );

    await preferences.setString(_credentialsKey, encoded);
    await preferences.setInt(_nextIdKey, nextId);
  }

  int _nextIdAfter(List<Credential> credentials) {
    if (credentials.isEmpty) return 1;

    final highestId = credentials
        .map((credential) => credential.id)
        .reduce((current, next) => current > next ? current : next);
    return highestId + 1;
  }
}

class PasswordVault {
  static const String _key = 'DES3113-CipherVault-Key';

  static String encrypt(String value) {
    final bytes = utf8.encode(value);
    final keyBytes = utf8.encode(_key);
    final encrypted = <int>[];

    for (var i = 0; i < bytes.length; i++) {
      encrypted.add(bytes[i] ^ keyBytes[i % keyBytes.length]);
    }

    return base64Url.encode(encrypted);
  }

  static String decrypt(String value) {
    final bytes = base64Url.decode(value);
    final keyBytes = utf8.encode(_key);
    final decrypted = <int>[];

    for (var i = 0; i < bytes.length; i++) {
      decrypted.add(bytes[i] ^ keyBytes[i % keyBytes.length]);
    }

    return utf8.decode(decrypted);
  }
}

enum PasswordStrength {
  weak('Weak', Color(0xFFDC2626), 0.25),
  fair('Fair', Color(0xFFF59E0B), 0.5),
  good('Good', Color(0xFF0891B2), 0.75),
  strong('Strong', Color(0xFF16A34A), 1);

  const PasswordStrength(this.label, this.color, this.progress);

  final String label;
  final Color color;
  final double progress;
}

PasswordStrength evaluatePassword(String password) {
  var score = 0;

  if (password.length >= 8) score++;
  if (password.length >= 12) score++;
  if (RegExp(r'[A-Z]').hasMatch(password)) score++;
  if (RegExp(r'[a-z]').hasMatch(password)) score++;
  if (RegExp(r'\d').hasMatch(password)) score++;
  if (RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=/\\[\];]').hasMatch(password)) {
    score++;
  }

  if (score <= 2) return PasswordStrength.weak;
  if (score <= 4) return PasswordStrength.fair;
  if (score == 5) return PasswordStrength.good;
  return PasswordStrength.strong;
}

class PasswordManagerScreen extends StatefulWidget {
  const PasswordManagerScreen({super.key});

  @override
  State<PasswordManagerScreen> createState() => _PasswordManagerScreenState();
}

class _PasswordManagerScreenState extends State<PasswordManagerScreen> {
  final CredentialStorage _storage = CredentialStorage();
  List<Credential> _credentials = [];
  int _nextId = 1;
  bool _isUnlocked = false;
  bool _isLoading = true;
  String _query = '';
  final Set<int> _visiblePasswords = <int>{};

  String get _currentUsername {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return '';
    final email = user.email ?? '';
    return email.replaceAll('@ciphervault.app', '');
  }

  List<Credential> get _filteredCredentials {
    final query = _query.toLowerCase().trim();
    if (query.isEmpty) return _credentials;

    return _credentials.where((credential) {
      return credential.platform.toLowerCase().contains(query) ||
          credential.username.toLowerCase().contains(query) ||
          credential.category.toLowerCase().contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    // Do NOT load vault here — the user is not authenticated yet.
    // _loadSavedVault is called from _unlockVault after auth succeeds.
  }

  Future<void> _signOut() async {
    await _storage.clearLocal();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    setState(() {
      _isUnlocked = false;
      _credentials = [];
      _nextId = 1;
      _isLoading = true;
      _visiblePasswords.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isUnlocked) {
      return _AuthGate(onUnlock: _unlockVault);
    }

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF7F9FC),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final filteredCredentials = _filteredCredentials;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CipherVault'),
            if (_currentUsername.isNotEmpty)
              Text(
                _currentUsername,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF64748B),
                ),
              ),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Profile',
            onPressed: _openProfileSheet,
            icon: const Icon(Icons.manage_accounts_outlined),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCredentialForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add platform'),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _VaultSummary(
                      totalplatforms: _credentials.length,
                      strongplatforms: _credentials.where((credential) {
                        final password = PasswordVault.decrypt(
                          credential.encryptedPassword,
                        );
                        return evaluatePassword(password) ==
                            PasswordStrength.strong;
                      }).length,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: 'Search platforms, usernames, categories',
                          prefixIcon: const Icon(Icons.search, color: Color(0xFF64748B)),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
                          ),
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Saved platforms',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (filteredCredentials.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyVault(),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverList.separated(
                  itemBuilder: (context, index) {
                    final credential = filteredCredentials[index];
                    final password = PasswordVault.decrypt(
                      credential.encryptedPassword,
                    );
                    final isVisible = _visiblePasswords.contains(credential.id);

                    return _CredentialCard(
                      credential: credential,
                      password: password,
                      isVisible: isVisible,
                      onToggleVisibility: () {
                        setState(() {
                          if (isVisible) {
                            _visiblePasswords.remove(credential.id);
                          } else {
                            _visiblePasswords.add(credential.id);
                          }
                        });
                      },
                      onEdit: () => _openCredentialForm(credential: credential),
                      onDelete: () => _deleteCredential(credential),
                    );
                  },
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemCount: filteredCredentials.length,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _unlockVault() {
    setState(() => _isUnlocked = true);
    // Load the vault NOW — the user is authenticated and currentUser?.uid is set.
    _loadSavedVault();
  }

  Future<void> _openProfileSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ProfileSheet(
        username: _currentUsername,
        onChangeUsername: _changeUsername,
        onChangePin: _changePin,
        onDeleteAccount: _deleteAccount,
      ),
    );
  }

  Future<bool> _changeUsername(String newUsername, String pin) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final oldEmail = user.email!;
    final oldUid = user.uid;
    final newEmail = _usernameToEmail(newUsername);

    try {
      // 1. Re-authenticate the current user with their PIN
      final credential = EmailAuthProvider.credential(
        email: oldEmail,
        password: pin,
      );
      await user.reauthenticateWithCredential(credential);

      // 2. Try to create the new user account (this logs them in if it succeeds)
      String newUid;
      try {
        final newUserCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: newEmail,
          password: pin,
        );
        newUid = newUserCredential.user!.uid;
      } on FirebaseAuthException catch (e) {
        if (e.code == 'email-already-in-use') {
          if (!mounted) return false;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Username is already taken.')),
          );
          return false;
        }
        rethrow;
      }

      // 3. Copy SharedPreferences keys from oldUid to newUid
      final preferences = await SharedPreferences.getInstance();
      final oldCredentialsKey = 'cipher_vault_credentials_$oldUid';
      final oldNextIdKey = 'cipher_vault_next_id_$oldUid';
      final savedCredentials = preferences.getString(oldCredentialsKey);
      final savedNextId = preferences.getInt(oldNextIdKey) ?? _nextId;

      if (savedCredentials != null) {
        final newCredentialsKey = 'cipher_vault_credentials_$newUid';
        final newNextIdKey = 'cipher_vault_next_id_$newUid';
        await preferences.setString(newCredentialsKey, savedCredentials);
        await preferences.setInt(newNextIdKey, savedNextId);
      }

      // 4. Save the credentials to Firestore under the new UID
      await FirebaseFirestore.instance
          .collection('passwordVaults')
          .doc(newUid)
          .set({
            'credentials': _credentials.map((c) => c.toJson()).toList(),
            'nextId': _nextId,
            'updatedAt': FieldValue.serverTimestamp(),
          });

      // 5. Log back in to the old user to delete their Firestore vault and Auth account
      try {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: oldEmail,
          password: pin,
        );
        // Delete old Firestore vault
        await FirebaseFirestore.instance
            .collection('passwordVaults')
            .doc(oldUid)
            .delete();
        // Delete old local keys
        await preferences.remove(oldCredentialsKey);
        await preferences.remove(oldNextIdKey);
        // Delete old Auth user
        await FirebaseAuth.instance.currentUser?.delete();
      } catch (e) {
        debugPrint('Failed to clean up old account: $e');
      }

      // 6. Finally, log in to the new user
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: newEmail,
        password: pin,
      );

      // Reload vault state (updates _credentials, _nextId, and triggers UI refresh)
      await _loadSavedVault();
      return true;
    } on FirebaseAuthException catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Failed to update username.')),
      );
      return false;
    }
  }

  Future<bool> _changePin(String currentPin, String newPin) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      // Re-authenticate first
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: currentPin,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPin);
      return true;
    } on FirebaseAuthException catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Failed to update PIN.')),
      );
      return false;
    }
  }

  Future<void> _deleteAccount(String currentPin) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      // Re-authenticate before deleting
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: currentPin,
      );
      await user.reauthenticateWithCredential(credential);

      // Clear local storage first while user is still authenticated
      await _storage.clearLocal();

      // Delete Firestore vault
      await FirebaseFirestore.instance
          .collection('passwordVaults')
          .doc(user.uid)
          .delete();

      // Delete Firebase Auth account
      await user.delete();

      if (!mounted) return;
      setState(() {
        _isUnlocked = false;
        _credentials = [];
        _nextId = 1;
        _isLoading = true;
        _visiblePasswords.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account deleted successfully.')),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Failed to delete account.')),
      );
    }
  }


  Future<void> _loadSavedVault() async {
    final savedVault = await _storage.load();

    if (!mounted) return;

    setState(() {
      _credentials = savedVault.credentials;
      _nextId = savedVault.nextId;
      _isLoading = false;
    });
  }

  Future<void> _saveVault() async {
    await _storage.save(_credentials, _nextId);
  }

  Future<void> _openCredentialForm({Credential? credential}) async {
    final result = await showModalBottomSheet<CredentialFormResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => CredentialFormSheet(
        credential: credential,
        currentPassword: credential == null
            ? null
            : PasswordVault.decrypt(credential.encryptedPassword),
      ),
    );

    if (result == null) return;

    var shouldSave = false;

    setState(() {
      if (credential == null) {
        _credentials.add(
          Credential(
            id: _nextId++,
            platform: result.platform,
            username: result.username,
            encryptedPassword: PasswordVault.encrypt(result.password),
            category: result.category,
            link: result.link,
          ),
        );
        shouldSave = true;
      } else {
        final index = _credentials.indexWhere(
          (item) => item.id == credential.id,
        );
        if (index == -1) return;

        _credentials[index] = credential.copyWith(
          platform: result.platform,
          username: result.username,
          encryptedPassword: PasswordVault.encrypt(result.password),
          category: result.category,
          link: result.link,
        );
        shouldSave = true;
      }
    });

    if (shouldSave) {
      await _saveVault();
    }
  }

  Future<void> _deleteCredential(Credential credential) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${credential.platform}?'),
        content: const Text('This platform will be removed from your vault.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete != true) return;

    setState(() {
      _credentials.removeWhere((item) => item.id == credential.id);
      _visiblePasswords.remove(credential.id);
    });

    await _saveVault();
  }
}

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet({
    required this.username,
    required this.onChangeUsername,
    required this.onChangePin,
    required this.onDeleteAccount,
  });

  final String username;
  final Future<bool> Function(String newUsername, String pin) onChangeUsername;
  final Future<bool> Function(String currentPin, String newPin) onChangePin;
  final Future<void> Function(String currentPin) onDeleteAccount;

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  final _usernameController = TextEditingController();
  final _usernamePinController = TextEditingController();
  final _currentPinController = TextEditingController();
  final _newPinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  final _deletePinController = TextEditingController();
  bool _isUpdatingUsername = false;
  bool _isUpdatingPin = false;
  bool _isDeletingAccount = false;
  bool get _isProcessing => _isUpdatingUsername || _isUpdatingPin || _isDeletingAccount;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.username;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _usernamePinController.dispose();
    _currentPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    _deletePinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Text(
                'Profile Settings',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Change Username ──
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Change Username',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _usernameController,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'New username',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _usernamePinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      hintText: 'Current 6-digit PIN',
                      prefixIcon: Icon(Icons.lock_outline),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isProcessing
                          ? null
                          : () async {
                              final newUsername = _usernameController.text.trim();
                              final pin = _usernamePinController.text;
                              if (newUsername.isEmpty || newUsername.contains(' ')) {
                                setState(() => _errorMessage = 'Enter a valid username (no spaces).');
                                return;
                              }
                              if (pin.length != 6) {
                                setState(() => _errorMessage = 'Enter your 6-digit PIN to confirm.');
                                return;
                              }
                              final navigator = Navigator.of(context);
                              final messenger = ScaffoldMessenger.of(context);
                              setState(() {
                                _isUpdatingUsername = true;
                                _errorMessage = '';
                              });
                              final success = await widget.onChangeUsername(newUsername, pin);
                              if (mounted) {
                                setState(() => _isUpdatingUsername = false);
                                if (success) {
                                  navigator.pop();
                                  messenger.showSnackBar(
                                    const SnackBar(content: Text('Username updated successfully.')),
                                  );
                                }
                              }
                            },
                      child: _isUpdatingUsername
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Update Username'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Change PIN ──
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Change PIN',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _currentPinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      hintText: 'Current 6-digit PIN',
                      prefixIcon: Icon(Icons.lock_outline),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _newPinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      hintText: 'New 6-digit PIN',
                      prefixIcon: Icon(Icons.lock_reset),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmPinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      hintText: 'Confirm new PIN',
                      prefixIcon: Icon(Icons.lock_reset),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isProcessing
                          ? null
                          : () async {
                              final currentPin = _currentPinController.text;
                              final newPin = _newPinController.text;
                              final confirmPin = _confirmPinController.text;
                              if (currentPin.length != 6 || newPin.length != 6) {
                                setState(() => _errorMessage = 'PINs must be 6 digits.');
                                return;
                              }
                              if (newPin != confirmPin) {
                                setState(() => _errorMessage = 'New PINs do not match.');
                                return;
                              }
                              final navigator = Navigator.of(context);
                              final messenger = ScaffoldMessenger.of(context);
                              setState(() {
                                _isUpdatingPin = true;
                                _errorMessage = '';
                              });
                              final success = await widget.onChangePin(currentPin, newPin);
                              if (mounted) {
                                setState(() => _isUpdatingPin = false);
                                if (success) {
                                  navigator.pop();
                                  messenger.showSnackBar(
                                    const SnackBar(content: Text('PIN updated successfully.')),
                                  );
                                }
                              }
                            },
                      child: _isUpdatingPin
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Update PIN'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Delete Account ──
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFECACA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Delete Account',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFDC2626),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This will permanently delete your account and all saved passwords. This action cannot be undone.',
                    style: TextStyle(color: Color(0xFF991B1B), fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _deletePinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      hintText: 'Enter PIN to confirm',
                      prefixIcon: Icon(Icons.warning_amber_outlined, color: Color(0xFFDC2626)),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                      ),
                      onPressed: _isProcessing
                          ? null
                          : () async {
                              final pin = _deletePinController.text;
                              if (pin.length != 6) {
                                setState(() => _errorMessage = 'Enter your 6-digit PIN to confirm.');
                                return;
                              }
                              setState(() {
                                _isDeletingAccount = true;
                                _errorMessage = '';
                              });
                              Navigator.pop(context);
                              await widget.onDeleteAccount(pin);
                            },
                      child: _isDeletingAccount
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Delete My Account'),
                    ),
                  ),
                ],
              ),
            ),

            if (_errorMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Center(
                child: Text(
                  _errorMessage,
                  style: const TextStyle(
                    color: Color(0xFFDC2626),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Converts a plain username into a dummy Firebase-compatible email.
String _usernameToEmail(String username) =>
    '${username.trim().toLowerCase()}@ciphervault.app';

enum AuthGateMode { checkingAuth, login, setupStep1, setupStep2, loggingIn }

class _AuthGate extends StatefulWidget {
  const _AuthGate({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  AuthGateMode _mode = AuthGateMode.checkingAuth;
  final _usernameController = TextEditingController();
  String _enteredPin = '';
  String _setupPin1 = '';
  String _errorMessage = '';
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _checkExistingSession() async {
    // If already signed in from a previous session, unlock immediately.
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      widget.onUnlock();
      return;
    }
    if (mounted) setState(() => _mode = AuthGateMode.login);
  }

  void _onKeyPress(String key) {
    if (_enteredPin.length < 6 && !_isProcessing) {
      setState(() {
        _enteredPin += key;
        _errorMessage = '';
      });
      if (_enteredPin.length == 6) {
        _processPin();
      }
    }
  }

  void _onBackspace() {
    if (_enteredPin.isNotEmpty && !_isProcessing) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
        _errorMessage = '';
      });
    }
  }

  Future<void> _onUsernameNext() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _errorMessage = 'Please enter a username.');
      return;
    }
    if (username.contains(' ')) {
      setState(() => _errorMessage = 'Username cannot contain spaces.');
      return;
    }
    setState(() {
      _errorMessage = '';
      _mode = AuthGateMode.setupStep1;
    });
  }

  Future<void> _processPin() async {
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;

    if (_mode == AuthGateMode.setupStep1) {
      setState(() {
        _setupPin1 = _enteredPin;
        _enteredPin = '';
        _mode = AuthGateMode.setupStep2;
      });
    } else if (_mode == AuthGateMode.setupStep2) {
      if (_enteredPin == _setupPin1) {
        await _createAccount(_enteredPin);
      } else {
        setState(() {
          _errorMessage = 'PINs do not match. Try again.';
          _enteredPin = '';
          _setupPin1 = '';
          _mode = AuthGateMode.setupStep1;
        });
      }
    } else if (_mode == AuthGateMode.loggingIn) {
      await _signIn(_enteredPin);
    }
  }

  Future<void> _createAccount(String pin) async {
    setState(() => _isProcessing = true);
    try {
      final email = _usernameToEmail(_usernameController.text);
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: pin,
      );
      widget.onUnlock();
    } on FirebaseAuthException catch (e) {
      String msg;
      if (e.code == 'email-already-in-use') {
        msg = 'Username already taken. Try logging in instead.';
      } else if (e.code == 'weak-password') {
        msg = 'PIN is too weak. Try a different combination.';
      } else {
        msg = e.message ?? 'Sign-up failed. Try again.';
      }
      setState(() {
        _errorMessage = msg;
        _enteredPin = '';
        _setupPin1 = '';
        _mode = AuthGateMode.setupStep1;
        _isProcessing = false;
      });
    }
  }

  Future<void> _signIn(String pin) async {
    setState(() => _isProcessing = true);
    try {
      final email = _usernameToEmail(_usernameController.text);
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: pin,
      );
      widget.onUnlock();
    } on FirebaseAuthException catch (e) {
      String msg;
      if (e.code == 'user-not-found') {
        msg = 'Username not found. Create an account instead.';
      } else if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        msg = 'Incorrect PIN. Please try again.';
      } else {
        msg = e.message ?? 'Login failed. Try again.';
      }
      setState(() {
        _errorMessage = msg;
        _enteredPin = '';
        _isProcessing = false;
      });
    }
  }

  void _switchToLogin() {
    setState(() {
      _enteredPin = '';
      _setupPin1 = '';
      _errorMessage = '';
      _mode = AuthGateMode.loggingIn;
    });
  }

  void _switchToSignup() {
    setState(() {
      _enteredPin = '';
      _setupPin1 = '';
      _errorMessage = '';
      _mode = AuthGateMode.setupStep1;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_mode == AuthGateMode.checkingAuth) {
      return const Scaffold(
        backgroundColor: Color(0xFFEAF2FF),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final bool showUsernameField = _mode == AuthGateMode.login;
    final bool showPinPad = _mode == AuthGateMode.setupStep1 ||
        _mode == AuthGateMode.setupStep2 ||
        _mode == AuthGateMode.loggingIn;

    String title;
    String subtitle;
    switch (_mode) {
      case AuthGateMode.login:
        title = 'Welcome to CipherVault';
        subtitle = 'Enter your username to get started';
        break;
      case AuthGateMode.setupStep1:
        title = 'Create a PIN';
        subtitle = 'Set a 6-digit PIN for @${_usernameController.text.trim()}';
        break;
      case AuthGateMode.setupStep2:
        title = 'Confirm PIN';
        subtitle = 'Re-enter your 6-digit PIN';
        break;
      case AuthGateMode.loggingIn:
        title = 'Enter PIN';
        subtitle = 'Enter your PIN for @${_usernameController.text.trim()}';
        break;
      default:
        title = '';
        subtitle = '';
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFEAF2FF), Color(0xFFF9FAFB)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF2563EB).withOpacity(0.15),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          )
                        ],
                      ),
                      child: const Icon(
                        Icons.lock_outline,
                        size: 48,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: const Color(0xFF4B5563),
                    ),
                  ),
                  const SizedBox(height: 28),

                  if (showUsernameField) ...[
                    TextField(
                      controller: _usernameController,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() => _errorMessage = ''),
                      onSubmitted: (_) => _onUsernameNext(),
                      decoration: InputDecoration(
                        hintText: 'Username',
                        prefixIcon: const Icon(Icons.person_outline),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    if (_errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage,
                        style: const TextStyle(
                          color: Color(0xFFDC2626),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _isProcessing ? null : () async {
                          if (_usernameController.text.trim().isEmpty) {
                            setState(() => _errorMessage = 'Enter your username first.');
                            return;
                          }
                          setState(() => _isProcessing = true);
                          try {
                            final email = _usernameToEmail(_usernameController.text);
                            // Attempt to create the user to see if it already exists
                            final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
                              email: email,
                              password: 'DummyPassword123!', 
                            );
                            // If it succeeds, the user did NOT exist.
                            // Delete the dummy user and show the required message.
                            await cred.user?.delete();
                            await FirebaseAuth.instance.signOut();
                            setState(() {
                              _errorMessage = 'Username dont exist, please create new username';
                              _isProcessing = false;
                            });
                            return;
                          } on FirebaseAuthException catch (e) {
                            if (e.code == 'email-already-in-use') {
                              // User exists! We can safely proceed to the PIN pad.
                            } else {
                              // If there is any other error (like network issue), show it.
                              setState(() {
                                _errorMessage = 'Username dont exist, please create new username';
                                _isProcessing = false;
                              });
                              return;
                            }
                          } catch (e) {
                            setState(() {
                              _errorMessage = 'Username dont exist, please create new username';
                              _isProcessing = false;
                            });
                            return;
                          }
                          setState(() => _isProcessing = false);
                          _switchToLogin();
                        },
                        child: _isProcessing
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Log in with existing account'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF2563EB),
                          side: const BorderSide(
                            color: Color(0xFF2563EB),
                            width: 1.5,
                          ),
                        ),
                        onPressed: _onUsernameNext,
                        child: const Text('Sign up with new account'),
                      ),
                    ),
                  ],

                  if (showPinPad) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(6, (index) {
                        final isFilled = index < _enteredPin.length;
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isFilled
                                ? const Color(0xFF2563EB)
                                : const Color(0xFFCBD5E1),
                          ),
                        );
                      }),
                    ),
                    if (_errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFDC2626),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 36),
                    ],
                    if (_isProcessing)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: CircularProgressIndicator(),
                      )
                    else
                      Expanded(
                        child: GridView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 1.5,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                          itemCount: 12,
                          itemBuilder: (context, index) {
                            if (index == 9) return const SizedBox.shrink();
                            if (index == 11) {
                              return _PinButton(
                                onPressed: _onBackspace,
                                icon: Icons.backspace_outlined,
                              );
                            }
                            final number = index == 10 ? '0' : '${index + 1}';
                            return _PinButton(
                              onPressed: () => _onKeyPress(number),
                              text: number,
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _enteredPin = '';
                          _setupPin1 = '';
                          _errorMessage = '';
                          _isProcessing = false;
                          _mode = AuthGateMode.login;
                        });
                      },
                      child: const Text('← Back to username'),
                    ),
                    if (_mode == AuthGateMode.loggingIn)
                      TextButton(
                        onPressed: _switchToSignup,
                        child: const Text('Create a new account instead'),
                      ),
                    if (_mode == AuthGateMode.setupStep1 || _mode == AuthGateMode.setupStep2)
                      TextButton(
                        onPressed: _switchToLogin,
                        child: const Text('Already have an account? Log in'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _PinButton extends StatelessWidget {
  const _PinButton({required this.onPressed, this.text, this.icon});

  final VoidCallback onPressed;
  final String? text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        splashColor: const Color(0xFF2563EB).withOpacity(0.1),
        highlightColor: const Color(0xFF2563EB).withOpacity(0.05),
        child: Center(
          child: icon != null
              ? Icon(icon, color: const Color(0xFF111827), size: 28)
              : Text(
                  text!,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111827),
                  ),
                ),
        ),
      ),
    );
  }
}

class _VaultSummary extends StatelessWidget {
  const _VaultSummary({
    required this.totalplatforms,
    required this.strongplatforms,
  });

  final int totalplatforms;
  final int strongplatforms;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.enhanced_encryption),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Encrypted password vault',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SummaryMetric(
                  label: 'platforms',
                  value: totalplatforms.toString(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryMetric(
                  label: 'Strong',
                  value: strongplatforms.toString(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFFCBD5E1)),
          ),
        ],
      ),
    );
  }
}

class _CredentialCard extends StatelessWidget {
  const _CredentialCard({
    required this.credential,
    required this.password,
    required this.isVisible,
    required this.onToggleVisibility,
    required this.onEdit,
    required this.onDelete,
  });

  final Credential credential;
  final String password;
  final bool isVisible;
  final VoidCallback onToggleVisibility;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final strength = evaluatePassword(password);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFFDBEAFE),
                  foregroundColor: const Color(0xFF1D4ED8),
                  child: Text(
                    credential.platform.characters.first.toUpperCase(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        credential.platform,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        credential.username,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF64748B),
                        ),
                      ),
                      if (credential.link.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        InkWell(
                          onTap: () async {
                            var url = credential.link;
                            if (!url.startsWith('http://') && !url.startsWith('https://')) {
                              url = 'https://$url';
                            }
                            final uri = Uri.parse(url);
                            try {
                              await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Could not launch link: $e'),
                                  ),
                                );
                              }
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.link, size: 14, color: Color(0xFF3B82F6)),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    credential.link,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF3B82F6),
                                      decoration: TextDecoration.underline,
                                      decorationColor: const Color(0xFF3B82F6),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'platform actions',
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Edit password'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isVisible ? password : '************',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: isVisible ? 0 : 1.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: isVisible ? 'Hide password' : 'Show password',
                    onPressed: onToggleVisibility,
                    icon: Icon(
                      isVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: strength.progress,
                      minHeight: 8,
                      color: strength.color,
                      backgroundColor: const Color(0xFFE2E8F0),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  strength.label,
                  style: TextStyle(
                    color: strength.color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: Color(0xFF64748B),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Encrypted value: ${credential.encryptedPassword}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CredentialFormResult {
  const CredentialFormResult({
    required this.platform,
    required this.username,
    required this.password,
    required this.category,
    required this.link,
  });

  final String platform;
  final String username;
  final String password;
  final String category;
  final String link;
}

class CredentialFormSheet extends StatefulWidget {
  const CredentialFormSheet({super.key, this.credential, this.currentPassword});

  final Credential? credential;
  final String? currentPassword;

  @override
  State<CredentialFormSheet> createState() => _CredentialFormSheetState();
}

class _CredentialFormSheetState extends State<CredentialFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _platformController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _categoryController;
  late final TextEditingController _linkController;
  bool _obscurePassword = true;

  bool get _isEditing => widget.credential != null;

  @override
  void initState() {
    super.initState();
    _platformController = TextEditingController(
      text: widget.credential?.platform ?? '',
    );
    _usernameController = TextEditingController(
      text: widget.credential?.username ?? '',
    );
    _passwordController = TextEditingController(
      text: widget.currentPassword ?? '',
    );
    _categoryController = TextEditingController(
      text: widget.credential?.category ?? '',
    );
    _linkController = TextEditingController(
      text: widget.credential?.link ?? '',
    );
  }

  @override
  void dispose() {
    _platformController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _categoryController.dispose();
    _linkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strength = evaluatePassword(_passwordController.text);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isEditing ? 'Edit password' : 'Add platform',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _platformController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Platform',
                  prefixIcon: Icon(Icons.account_circle_outlined),
                ),
                validator: _requiredValidator,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _usernameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Username or email',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
                validator: _requiredValidator,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _categoryController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: _requiredValidator,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _linkController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Link (Optional)',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.password),
                  suffixIcon: IconButton(
                    tooltip: _obscurePassword
                        ? 'Show password'
                        : 'Hide password',
                    onPressed: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  final message = _requiredValidator(value);
                  if (message != null) return message;
                  if (value!.length < 8) {
                    return 'Use at least 8 characters.';
                  }
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: strength.progress),
                        duration: const Duration(milliseconds: 300),
                        builder: (context, value, _) => LinearProgressIndicator(
                          value: value,
                          minHeight: 8,
                          color: strength.color,
                          backgroundColor: const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    strength.label,
                    style: TextStyle(
                      color: strength.color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: Icon(_isEditing ? Icons.save_outlined : Icons.add),
                  label: Text(_isEditing ? 'Save changes' : 'Create platform'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'This field is required.';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.pop(
      context,
      CredentialFormResult(
        platform: _platformController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        category: _categoryController.text.trim(),
        link: _linkController.text.trim(),
      ),
    );
  }
}

class _EmptyVault extends StatelessWidget {
  const _EmptyVault();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: const BoxDecoration(
                color: Color(0xFFE0E7FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.shield_outlined, size: 80, color: Color(0xFF4F46E5)),
            ),
            const SizedBox(height: 24),
            Text(
              'Your vault is empty',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add a new platform to keep your passwords secure and accessible.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF64748B),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
