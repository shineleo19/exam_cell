import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';

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
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, 'exam_admin_v14.db');

    var db = await openDatabase(path, version: 1, onCreate: _onCreate);
    await _seedDatabaseIfEmpty(db);
    return db;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('CREATE TABLE master_staff(staff_id TEXT PRIMARY KEY, staff_name TEXT)');
    await db.execute('CREATE TABLE daily_allotment(id INTEGER PRIMARY KEY, staff_name TEXT, hall_no TEXT, status TEXT DEFAULT "PENDING")');
    await db.execute('CREATE TABLE attendance_log(id INTEGER PRIMARY KEY, staff_id TEXT, staff_name TEXT, hall_no TEXT, timestamp TEXT, entry_status TEXT)');
    await db.execute('CREATE TABLE staff_aliases(master_name TEXT, alias_name TEXT)');
  }

  // --- NEW: COUNTERS FOR DASHBOARD TICKS ---
  Future<int> getMasterCount() async => Sqflite.firstIntValue(await (await database).rawQuery('SELECT COUNT(*) FROM master_staff')) ?? 0;
  Future<int> getDailyCount() async => Sqflite.firstIntValue(await (await database).rawQuery('SELECT COUNT(*) FROM daily_allotment')) ?? 0;

  // --- LATE ENTRY LOGIC ---
  String _calculateStatus(DateTime dt) {
    DateTime threshold = DateTime(dt.year, dt.month, dt.day, 7, 50);
    return dt.isAfter(threshold) ? "LATE ENTRY" : "ON TIME";
  }

  // --- ATTENDANCE FUNCTIONS ---
  Future<void> markAttendance(String id, String name, String hall) async {
    final db = await database;
    DateTime now = DateTime.now();
    String status = _calculateStatus(now);

    await db.insert('attendance_log', {
      'staff_id': id.trim().toUpperCase(),
      'staff_name': name,
      'hall_no': hall,
      'timestamp': now.toString(),
      'entry_status': status
    });
    await db.update('daily_allotment', {'status': 'PRESENT'}, where: 'hall_no = ?', whereArgs: [hall]);
  }

  Future<void> substituteAndLink(String newId, String newName, String targetHall) async {
    final db = await database;
    DateTime now = DateTime.now();
    String status = _calculateStatus(now);
    String cleanId = newId.trim().toUpperCase();

    await db.insert('master_staff', {'staff_id': cleanId, 'staff_name': newName}, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update('daily_allotment', {'staff_name': newName, 'status': 'PRESENT'}, where: 'hall_no = ?', whereArgs: [targetHall]);
    await db.insert('attendance_log', {
      'staff_id': cleanId,
      'staff_name': newName,
      'hall_no': targetHall,
      'timestamp': now.toString(),
      'entry_status': status
    });
  }

  // --- LOOKUP & ALIAS LOGIC ---
  Future<void> addAlias(String masterName, String scheduleName) async {
    final db = await database;
    var exist = await db.query('staff_aliases', where: 'master_name = ? AND alias_name = ?', whereArgs: [masterName, scheduleName]);
    if (exist.isEmpty) {
      await db.insert('staff_aliases', {'master_name': masterName, 'alias_name': scheduleName});
    }
  }

  Future<Map<String, dynamic>?> checkStaffStatus(String scannedId) async {
    final db = await database;
    String cleanId = scannedId.trim().toUpperCase();

    var log = await db.query('attendance_log', where: 'staff_id = ?', whereArgs: [cleanId], limit: 1);
    if (log.isNotEmpty) return {'type': 'LOGGED', 'staff_name': log.first['staff_name'], 'hall_no': log.first['hall_no']};

    var master = await db.query('master_staff', where: 'staff_id = ?', whereArgs: [cleanId]);
    if (master.isNotEmpty) {
      String name = master.first['staff_name'].toString();
      var schedule = await _findScheduleSmart(name);

      if (schedule != null) {
        return {'type': 'SCHEDULED', 'staff_name': schedule['staff_name'], 'hall_no': schedule['hall_no']};
      }
      return {'type': 'NOT_ALLOTTED', 'staff_name': name};
    }
    return {'type': 'UNKNOWN_ID', 'id': cleanId};
  }

  Future<Map<String, dynamic>?> _findScheduleSmart(String targetName) async {
    final db = await database;
    // 1. Aliases
    var aliases = await db.query('staff_aliases', columns: ['alias_name'], where: 'master_name = ?', whereArgs: [targetName]);
    for (var aliasRow in aliases) {
      String knownAlias = aliasRow['alias_name'].toString();
      var match = await db.query('daily_allotment', where: 'staff_name = ?', whereArgs: [knownAlias], limit: 1);
      if (match.isNotEmpty) return match.first;
    }
    // 2. Fuzzy
    var allRows = await db.query('daily_allotment');
    List<String> targetTokens = _tokenize(targetName);
    for (var row in allRows) {
      if (_isFuzzyMatch(targetTokens, _tokenize(row['staff_name'].toString()))) return row;
    }
    return null;
  }

  List<String> _tokenize(String name) {
    String clean = name.toLowerCase().replaceAll(RegExp(r'\b(dr|mr|ms|mrs|prof|er|ar)\b\.?'), '').replaceAll(RegExp(r'[^a-z\s]'), ' ').trim();
    return clean.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  bool _isFuzzyMatch(List<String> tokensA, List<String> tokensB) {
    if (tokensA.isEmpty || tokensB.isEmpty) return false;
    var setA = tokensA.toSet();
    var setB = tokensB.toSet();
    int matches = setA.intersection(setB).length;
    if (matches >= 2) return true;
    if (matches == 1) {
      String match = setA.intersection(setB).first;
      if (match.length > 3) return true;
    }
    return false;
  }

  Future<void> _seedDatabaseIfEmpty(Database db) async {
    var count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM master_staff'));
    if (count == 0) {
      try {
        ByteData data = await rootBundle.load("assets/finale.xlsx");
        var bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        var decoder = SpreadsheetDecoder.decodeBytes(bytes);
        Batch batch = db.batch();
        for (var table in decoder.tables.keys) {
          var sheet = decoder.tables[table]!;
          int nameCol = -1;
          int idCol = -1;
          for (int i = 0; i < (sheet.rows.length < 10 ? sheet.rows.length : 10); i++) {
            var row = sheet.rows[i];
            for (int j = 0; j < row.length; j++) {
              String cell = row[j]?.toString().toLowerCase() ?? "";
              if (cell.contains("name") || cell.contains("faculty")) nameCol = j;
              if (cell.contains("id") || cell.contains("emp")) idCol = j;
            }
            if (nameCol != -1) break;
          }
          if (nameCol == -1) nameCol = 1;
          for (int i = 1; i < sheet.rows.length; i++) {
            var row = sheet.rows[i];
            if (row.length <= nameCol) continue;
            String name = row[nameCol]?.toString().trim() ?? "";
            if (name.isEmpty || name.toLowerCase() == "null") continue;
            String finalId = "";
            if (idCol != -1 && row.length > idCol && row[idCol] != null) finalId = row[idCol].toString().trim().toUpperCase();
            if (finalId.isEmpty || (int.tryParse(finalId) != null && finalId.length < 4)) finalId = "TEMP_" + name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
            batch.insert('master_staff', {'staff_id': finalId, 'staff_name': name}, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        await batch.commit(noResult: true);
      } catch (e) {}
    }
  }

  Future<List<String>> getAllAvailableNames() async {
    final db = await database;
    var schedule = await db.query('daily_allotment', columns: ['staff_name']);
    var master = await db.query('master_staff', columns: ['staff_name']);
    Set<String> names = {};
    for (var row in schedule) names.add(row['staff_name'].toString());
    for (var row in master) names.add(row['staff_name'].toString());
    return names.toList()..sort();
  }

  Future<void> linkStaff(String id, String name) async => (await database).insert('master_staff', {'staff_id': id.toUpperCase(), 'staff_name': name}, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<void> clearMasterList() async => (await database).delete('master_staff');
  Future<void> clearDailySchedule() async => (await database).delete('daily_allotment');
  Future<void> insertMasterStaff(String id, String name) async => (await database).insert('master_staff', {'staff_id': id.toUpperCase(), 'staff_name': name});
  Future<void> insertDailyAllotment(String name, String hall) async => (await database).insert('daily_allotment', {'staff_name': name, 'hall_no': hall});
  Future<int> getPendingCount() async => Sqflite.firstIntValue(await (await database).rawQuery('SELECT COUNT(*) FROM daily_allotment')) ?? 0;
  Future<List<Map<String, dynamic>>> getPendingHalls() async => (await database).query('daily_allotment', where: 'status = ?', whereArgs: ['PENDING']);
  Future<List<Map<String, dynamic>>> getAllLogs() async => (await database).query('attendance_log');

  Future<void> resetDatabase() async {
    final db = await database;
    await db.delete('daily_allotment');
    await db.delete('attendance_log');
  }
}