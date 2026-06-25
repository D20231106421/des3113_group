import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'Firebase options are only configured for Android.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAr8xpg4HXWlB0csy33quPmznOe2H_pQUY',
    appId: '1:287795643507:android:9ba061cdf4c8705635d606',
    messagingSenderId: '287795643507',
    projectId: 'des3113-group',
    storageBucket: 'des3113-group.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCCUNYoOtsxMISPWFwK8sV2fPcUBEjbPVc',
    appId: '1:287795643507:web:0227fc0d20d143cb35d606',
    messagingSenderId: '287795643507',
    projectId: 'des3113-group',
    authDomain: 'des3113-group.firebaseapp.com',
    storageBucket: 'des3113-group.firebasestorage.app',
    measurementId: 'G-CGSY5DKXSF',
  );
}
