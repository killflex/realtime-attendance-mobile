import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../DB/DatabaseHelper.dart';

class RegisteredFacesScreen extends StatefulWidget {
  const RegisteredFacesScreen({super.key});

  @override
  State<RegisteredFacesScreen> createState() => _RegisteredFacesScreenState();
}

class _RegisteredFacesScreenState extends State<RegisteredFacesScreen> {
  final dbHelper = DatabaseHelper();
  List<Map<String, dynamic>> faces = [];

  @override
  void initState() {
    super.initState();
    loadFaces();
  }

  Future<void> loadFaces() async {
    await dbHelper.init();
    final data = await dbHelper.queryAllRows();
    setState(() {
      faces = data;
    });
  }

  Future<void> deleteFace(int id) async {
    await dbHelper.delete(id);
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
      appBar: AppBar(title: const Text('Registered Faces')),
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
                  Uint8List? imageBytes = face[DatabaseHelper.columnImage];

                  return Card.outlined(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child:
                            imageBytes != null
                                ? Image.memory(
                                  imageBytes,
                                  width: 56,
                                  height: 56,
                                  fit: BoxFit.cover,
                                )
                                : CircleAvatar(
                                  radius: 28,
                                  backgroundColor:
                                      colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.person,
                                    size: 32,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                      ),
                      title: Text(
                        face[DatabaseHelper.columnName] ?? '',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text('ID: ${face[DatabaseHelper.columnId]}'),
                      trailing: IconButton(
                        icon: Icon(
                          Icons.delete_rounded,
                          color: colorScheme.error,
                        ),
                        onPressed:
                            () => _confirmDelete(
                              context,
                              face[DatabaseHelper.columnId],
                            ),
                      ),
                    ),
                  );
                },
              ),
    );
  }

  @override
  void dispose() {
    dbHelper.close();
    super.dispose();
  }
}
