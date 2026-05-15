import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class ErrorScreen extends StatelessWidget {
  final String title;
  final String message;
  final String? details;
  final IconData icon;
  final Color iconColor;
  final List<Widget>? actions;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;

  const ErrorScreen({
    super.key,
    required this.title,
    required this.message,
    this.details,
    this.icon = Icons.error_outline,
    this.iconColor = Colors.red,
    this.actions,
    this.onRetry,
    this.onBack,
  });

  // Factory method untuk error kamera
  factory ErrorScreen.cameraError({
    VoidCallback? onRetry,
    VoidCallback? onBack,
  }) {
    return ErrorScreen(
      title: 'Kamera Tidak Tersedia',
      message:
          'Aplikasi ini membutuhkan kamera untuk melakukan absensi wajah.\n\nPastikan:',
      details:
          '• Perangkat Anda memiliki kamera\n• Kamera tidak digunakan oleh aplikasi lain\n• Izin kamera sudah diberikan',
      icon: Icons.camera_alt_outlined,
      iconColor: Colors.orange,
      onRetry: onRetry,
      onBack: onBack,
      actions: [
        if (onBack != null)
          ElevatedButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Kembali'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey,
              foregroundColor: Colors.white,
            ),
          ),
        if (onRetry != null)
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Coba Lagi'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
          ),
      ],
    );
  }

  // Factory method untuk error izin
  factory ErrorScreen.permissionDenied({VoidCallback? onRetry}) {
    return ErrorScreen(
      title: 'Izin Kamera Diperlukan',
      message:
          'Aplikasi ini membutuhkan izin kamera untuk melakukan absensi wajah.',
      details: 'Silakan berikan izin kamera di pengaturan perangkat Anda.',
      icon: Icons.security_outlined,
      iconColor: Colors.amber,
      onRetry: onRetry,
      actions: [
        ElevatedButton.icon(
          onPressed: () => openAppSettings(),
          icon: const Icon(Icons.settings),
          label: const Text('Buka Pengaturan'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.amber,
            foregroundColor: Colors.black,
          ),
        ),
        if (onRetry != null)
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Coba Lagi'),
          ),
      ],
    );
  }

  // Factory method untuk error model TensorFlow
  factory ErrorScreen.modelError({VoidCallback? onRetry}) {
    return ErrorScreen(
      title: 'Model AI Tidak Ditemukan',
      message: 'Model face recognition tidak dapat dimuat.',
      details:
          'Pastikan file model tersedia dan tidak corrupt.\nHubungi developer jika masalah berlanjut.',
      icon: Icons.psychology_outlined,
      iconColor: Colors.purple,
      onRetry: onRetry,
      actions: [
        if (onRetry != null)
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.download),
            label: const Text('Unduh Ulang Model'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Animated icon
                TweenAnimationBuilder(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 500),
                  builder: (context, double value, child) {
                    return Transform.scale(scale: value, child: child);
                  },
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 60, color: iconColor),
                  ),
                ),
                const SizedBox(height: 32),

                // Title
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                // Message
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Details card (optional)
                if (details != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 18,
                              color: Colors.grey.shade600,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Informasi Detail',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          details!,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ] else
                  const SizedBox(height: 24),

                // Action buttons
                if (actions != null && actions!.isNotEmpty)
                  Column(
                    children: [
                      ...actions!.map(
                        (action) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: action,
                          ),
                        ),
                      ),
                    ],
                  ),

                // Help text
                const SizedBox(height: 24),
                Text(
                  'Butuh bantuan? Hubungi support',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Wrapper untuk error dengan AppBar (opsional)
class ErrorApp extends StatelessWidget {
  final String title;
  final String message;
  final String? details;

  const ErrorApp({
    super.key,
    required this.title,
    required this.message,
    this.details,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Error',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: ErrorScreen(
        title: title,
        message: message,
        details: details,
        onRetry: () {
          // Reload app
          SystemChannels.platform.invokeMethod('SystemNavigator.pop');
        },
      ),
    );
  }
}
