import 'package:flutter/material.dart';

import 'recognition_screen.dart';
import 'registered_faces_screen.dart';
import 'registration_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 30),

            // Header Text
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Text(
                "Sistem Pengenalan Wajah MobileFaceNet",
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 60),

            // Logo
            Hero(
              tag: 'app_logo',
              child: Image.asset(
                "images/logo.png",
                width: screenWidth * 0.55,
                height: screenWidth * 0.55,
                fit: BoxFit.contain,
              ),
            ),

            const SizedBox(height: 40),

            // Material 3 Cards with ListTile
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                children: [
                  Card.outlined(
                    elevation: 0,
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                    ),
                    child: InkWell(
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RegistrationScreen(),
                            ),
                          ),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.transparent,
                          child: Icon(Icons.person_add_rounded),
                        ),
                        title: const Text("Daftar Wajah Baru"),
                        subtitle: const Text(
                          "Ambil dan simpan data wajah pengguna baru",
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios_rounded),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Card.outlined(
                    elevation: 0,
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                    ),
                    child: InkWell(
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RecognitionScreen(),
                            ),
                          ),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.transparent,
                          child: Icon(Icons.filter_center_focus_rounded),
                        ),
                        title: const Text("Deteksi Wajah"),
                        subtitle: const Text(
                          "Identifikasi wajah terdaftar secara real-time",
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios_rounded),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Card.outlined(
                    elevation: 0,
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                    ),
                    child: InkWell(
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RegisteredFacesScreen(),
                            ),
                          ),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.transparent,
                          child: Icon(Icons.storage_rounded),
                        ),
                        title: const Text("Wajah Terdaftar"),
                        subtitle: const Text(
                          "Lihat semua data wajah yang tersimpan",
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios_rounded),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Footer
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: Column(
                children: [
                  Text(
                    'Copyright © 2026 Ferry Hasan',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
