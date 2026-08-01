ObexVault

ObexVault is a password manager built with Flutter. It supports both cloud sync and fully offline storage, and focuses on strong encryption and practical security features.

This was built as a final year BCA project.

Features
AES-256 encryption for all stored data
Choice between Cloud mode and Offline mode at signup (permanent choice)
Argon2id used for key derivation, so master passwords are never stored directly
App Lock with biometric authentication and PIN fallback
Panic Mode: shows a separate decoy vault, kept fully isolated from the real one
Breach checking using the Have I Been Pwned API (uses k-anonymity, so your actual password is never sent)
TOTP based two factor authentication
Secure file vault for storing sensitive files
Built in password generator
Vault health dashboard to spot weak or reused passwords
Encrypted export and import using a custom .obex file format
Dead Man's Switch: if you don't check in for a while, a scheduled job emails an encrypted backup to a chosen contact
Architecture

The app uses a repository pattern so the same code works in both cloud and offline modes.

Flutter and Dart for the app itself
Firebase Auth and Cloud Firestore (asia-south1 region) for cloud mode
Hive CE for local offline storage
VaultRepository as the main abstraction, with FirestoreVaultRepo and LocalVaultRepo as the two implementations
OfflineAuthManager handles offline login using Argon2id, storing only a salt and an HMAC-SHA256 verifier in FlutterSecureStorage
App Lock is built using FlutterFragmentActivity and WidgetsBindingObserver, with checks in place so it doesn't trigger again unnecessarily when the app resumes
The AES key used for encryption is synced across devices through Firestore, wrapped with a key derived from the user's UID
Tech stack
Flutter and Dart
Firebase Auth and Cloud Firestore
Hive CE
AES-256, Argon2id, HMAC-SHA256
flutter_secure_storage
GitHub Actions with Node.js, Firebase Admin SDK, and Nodemailer for the Dead Man's Switch job
Getting started
bash
git clone https://github.com/<your-username>/obexvault.git
cd obexvault
flutter pub get
flutter run

You will need the Flutter SDK installed, and if you plan to use Cloud mode, a Firebase project set up with the right config files.

Security notes

Master passwords and encryption keys are never stored anywhere. Only a salt and a verifier hash are kept, which are enough to check a password without ever storing it.

Panic Mode data is kept in separate collections and cannot be linked back to the real vault.

The Dead Man's Switch only fires once. After it sends the backup, it turns itself off and clears the stored data. It also will not fire while Panic Mode is active, so it can't be misused during a coercion situation.

Documentation

A full technical report covering the design and implementation is available separately.

Author

Atharva Sawant BCA Final Year Project, Navneet College of Arts, Science and Commerce, Mumbai (YCMOU) Guided by Prof. Satyendra Pal
