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

            // Header Text with Material 3
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                "Sistem Absensi Pengenalan Wajah",
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 40),

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
                  Card.filled(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.primaryContainer,
                        child: Icon(
                          Icons.person_add_rounded,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                      title: const Text("Daftar Wajah Baru"),
                      subtitle: const Text(
                        "Ambil dan simpan data wajah pengguna baru",
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios_rounded),
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RegistrationScreen(),
                            ),
                          ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card.filled(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.secondaryContainer,
                        child: Icon(
                          Icons.filter_center_focus_rounded,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                      title: const Text("Deteksi Wajah"),
                      subtitle: const Text(
                        "Identifikasi wajah terdaftar secara real-time",
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios_rounded),
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RecognitionScreen(),
                            ),
                          ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card.filled(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.tertiaryContainer,
                        child: Icon(
                          Icons.storage_rounded,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                      title: const Text("Wajah Terdaftar"),
                      subtitle: const Text(
                        "Lihat semua data wajah yang tersimpan",
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios_rounded),
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RegisteredFacesScreen(),
                            ),
                          ),
                    ),
                  ),
                ],
              ),
            ),

            // Footer with Material 3
            Divider(color: colorScheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  Text(
                    '© 2026 Sistem Absensi Pengenalan Wajah',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Made with ❤️ by Ferry Hasan',
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
