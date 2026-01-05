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
          (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            backgroundColor: Colors.white,
            title: const Text(
              'Confirm Deletion',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF09090b),
              ),
            ),
            content: const Text(
              'Are you sure you want to delete this face?',
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            ),
            actions: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFD1D5DB)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Color(0xFF09090b)),
                ),
                onPressed: () => Navigator.pop(context),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  elevation: 0,
                ),
                child: const Text('Delete'),
                onPressed: () {
                  Navigator.pop(context);
                  deleteFace(id);
                },
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text(
          'Registered Faces',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 18,
            color: Color(0xFF09090b),
          ),
        ),
        centerTitle: false,
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: const Color(0xFF09090b),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE5E7EB), height: 1),
        ),
      ),
      body: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child:
            faces.isEmpty
                ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.face_retouching_off,
                        size: 80,
                        color: Color(0xFF9CA3AF),
                      ),
                      SizedBox(height: 16),
                      Text(
                        "No faces registered yet.",
                        style: TextStyle(
                          fontSize: 16,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                )
                : ListView.builder(
                  itemCount: faces.length,
                  padding: const EdgeInsets.only(bottom: 20),
                  itemBuilder: (context, index) {
                    final face = faces[index];
                    Uint8List? imageBytes = face[DatabaseHelper.columnImage];

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .1),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child:
                                      imageBytes != null
                                          ? Image.memory(
                                            imageBytes,
                                            width: 72,
                                            height: 72,
                                            fit: BoxFit.cover,
                                          )
                                          : Container(
                                            width: 72,
                                            height: 72,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF9FAFB),
                                              border: Border.all(
                                                color: const Color(0xFFE5E7EB),
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: const Icon(
                                              Icons.person,
                                              size: 36,
                                              color: Color(0xFF9CA3AF),
                                            ),
                                          ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        face[DatabaseHelper.columnName] ?? '',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF09090b),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'ID: ${face[DatabaseHelper.columnId]}',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Color(0xFF6B7280),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Delete button at middle-right corner
                          Positioned(
                            top: 0,
                            bottom: 0,
                            right: 15,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap:
                                    () => _confirmDelete(
                                      context,
                                      face[DatabaseHelper.columnId],
                                    ),
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.delete,
                                    size: 24,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
      ),
    );
  }

  @override
  void dispose() {
    dbHelper.close();
    super.dispose();
  }
}
