import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    // For Windows/Linux, the database factory is set in main.dart via FFI
    // For Mobile, getApplicationDocumentsDirectory works standardly
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, 'exam_admin_dynamic_v14.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // 1. DAILY SCHEDULE
    await db.execute('''
      CREATE TABLE daily_allotment(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        staff_id TEXT,
        staff_name TEXT,
        hall_no TEXT,
        status TEXT DEFAULT 'PENDING'
      )
    ''');

    // 2. ATTENDANCE LOG
    await db.execute('''
      CREATE TABLE attendance_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        staff_id TEXT,
        staff_name TEXT,
        hall_no TEXT,
        timestamp TEXT
      )
    ''');
  }

  // --- CORE LOGIC START ---

  // 1. THE UNIFIED CHECK
  Future<Map<String, dynamic>?> checkStaffStatus(String scannedId) async {
    final db = await database;
    String cleanId = scannedId.trim().toUpperCase();

    // PRIORITY 1: Check Logs (Has this person ALREADY scanned or been swapped in?)
    List<Map<String, dynamic>> logResult = await db.query(
        'attendance_log',
        where: 'staff_id = ?',
        whereArgs: [cleanId],
        orderBy: 'id DESC', // Get most recent
        limit: 1
    );

    if (logResult.isNotEmpty) {
      return {
        'type': 'LOGGED', // Flag: Already processed
        'staff_name': logResult.first['staff_name'],
        'hall_no': logResult.first['hall_no'],
      };
    }

    // PRIORITY 2: Check Schedule (Is this a normal first-time scan?)
    List<Map<String, dynamic>> scheduleResult = await db.query(
        'daily_allotment',
        where: 'staff_id = ?',
        whereArgs: [cleanId]
    );

    if (scheduleResult.isNotEmpty) {
      return {
        'type': 'SCHEDULED', // Flag: Needs to be marked present
        'staff_name': scheduleResult.first['staff_name'],
        'hall_no': scheduleResult.first['hall_no'],
        'status': scheduleResult.first['status']
      };
    }

    // PRIORITY 3: Not found (Trigger Substitution)
    return null;
  }

  // 2. Mark Attendance for Normal Schedule
  Future<void> markAttendance(String id, String name, String hall) async {
    final db = await database;

    // Add to log
    await db.insert('attendance_log', {
      'staff_id': id,
      'staff_name': name,
      'hall_no': hall,
      'timestamp': DateTime.now().toString(),
    });

    // Update Schedule status
    await db.update(
        'daily_allotment',
        {'status': 'PRESENT'},
        where: 'staff_id = ? AND hall_no = ?',
        whereArgs: [id, hall]
    );
  }

  // 3. Mark Substitution (The Swap Logic)
  Future<void> markSubstitution(String newId, String newName, String hallNo) async {
    final db = await database;

    // A. Log the NEW person (So next scan finds them in Priority 1)
    await db.insert('attendance_log', {
      'staff_id': newId.trim().toUpperCase(),
      'staff_name': newName.trim(),
      'hall_no': hallNo,
      'timestamp': DateTime.now().toString(),
    });

    // B. Mark the Hall as Filled in the Schedule
    // We update by Hall No because the ID associated with this hall was the OLD person
    await db.update(
        'daily_allotment',
        {'status': 'PRESENT'},
        where: 'hall_no = ?',
        whereArgs: [hallNo]
    );
  }

  // --- HELPER GETTERS ---

  Future<List<Map<String, dynamic>>> getPendingHalls() async {
    final db = await database;
    return await db.query(
        'daily_allotment',
        columns: ['hall_no', 'staff_name'],
        where: 'status = ?',
        whereArgs: ['PENDING']
    );
  }

  Future<void> insertDailyAllotment(String id, String name, String hall) async {
    final db = await database;
    await db.insert('daily_allotment', {
      'staff_id': id.trim().toUpperCase(),
      'staff_name': name.trim(),
      'hall_no': hall,
      'status': 'PENDING'
    });
  }

  Future<List<Map<String, dynamic>>> getAllLogs() async {
    final db = await database;
    // Order by timestamp so the CSV is chronological
    return await db.query('attendance_log', orderBy: 'timestamp ASC');
  }

  Future<void> resetDatabase() async {
    final db = await database;
    await db.delete('daily_allotment');
    await db.delete('attendance_log');
  }

  Future<int> getPendingCount() async {
    final db = await database;
    var x = await db.rawQuery('SELECT COUNT(*) FROM daily_allotment');
    return Sqflite.firstIntValue(x) ?? 0;
  }
}