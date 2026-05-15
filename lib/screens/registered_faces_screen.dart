import 'package:flutter/material.dart';

import '../data/face_record.dart';
import '../data/face_repository.dart';
import '../di/service_locator.dart';

class RegisteredFacesScreen extends StatefulWidget {
  const RegisteredFacesScreen({super.key});

  @override
  State<RegisteredFacesScreen> createState() => _RegisteredFacesScreenState();
}

class _RegisteredFacesScreenState extends State<RegisteredFacesScreen> {
  final FaceRepository _faceRepository = getIt<FaceRepository>();
  List<FaceRecord> faces = [];

  @override
  void initState() {
    super.initState();
    loadFaces();
  }

  Future<void> loadFaces() async {
    final data = await _faceRepository.getAllFaces();
    setState(() {
      faces = data;
    });
  }

  Future<void> deleteFace(int id) async {
    await _faceRepository.deleteFace(id);
    loadFaces();
  }

  void _confirmDelete(BuildContext context, int id) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded),
            title: const Text('Confirm Deletion'),
            content: const Text('Are you sure you want to delete this face?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  deleteFace(id);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Daftar Wajah Pengguna')),
      body:
          faces.isEmpty
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.face_retouching_off_rounded,
                      size: 80,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      "No faces registered yet.",
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
              : ListView.builder(
                itemCount: faces.length,
                padding: const EdgeInsets.all(16),
                itemBuilder: (context, index) {
                  final face = faces[index];
                  final imageBytes = face.imageBytes;
                  final faceId = face.id ?? -1;

                  return Card.outlined(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          imageBytes,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                      title: Text(
                        face.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text('ID: ${faceId == -1 ? '-' : faceId}'),
                      trailing: IconButton(
                        icon: Icon(
                          Icons.delete_rounded,
                          color: colorScheme.error,
                        ),
                        onPressed:
                            faceId == -1
                                ? null
                                : () => _confirmDelete(context, faceId),
                      ),
                    ),
                  );
                },
              ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
