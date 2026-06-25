import 'package:des3113_group/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PasswordVault', () {
    test('encrypts and decrypts a password', () {
      const password = 'Secure#Password42';

      final encrypted = PasswordVault.encrypt(password);

      expect(encrypted, isNot(password));
      expect(PasswordVault.decrypt(encrypted), password);
    });
  });

  group('evaluatePassword', () {
    test('scores weak and strong passwords', () {
      expect(evaluatePassword('abc123'), PasswordStrength.weak);
      expect(evaluatePassword('Secure#Password42'), PasswordStrength.strong);
    });
  });

  group('CredentialStorage', () {
    test('saves and loads credentials locally', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = CredentialStorage();
      final credential = Credential(
        id: 1,
        platform: 'Bank',
        username: 'student',
        encryptedPassword: PasswordVault.encrypt('Bank#Password42'),
        category: 'Finance',
      );

      await storage.save([credential], 2);
      final savedVault = await storage.load();

      expect(savedVault.nextId, 2);
      expect(savedVault.credentials, hasLength(1));
      expect(savedVault.credentials.first.platform, 'Bank');
      expect(
        PasswordVault.decrypt(savedVault.credentials.first.encryptedPassword),
        'Bank#Password42',
      );
    });
  });
}
