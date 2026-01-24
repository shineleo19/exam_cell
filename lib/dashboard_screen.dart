import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'database_helper.dart';
import 'scanner_screen.dart';

class DashboardScreen extends StatefulWidget {
  @override
  _DashboardScreenState createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _status = "System Idle";
  bool _isLoading = false;
  int _recordCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  // --- LOGIC SECTION ---

  Future<void> _refreshStats() async {
    final count = await DatabaseHelper().getPendingCount();
    setState(() {
      _recordCount = count;
      _status = _recordCount > 0
          ? "Database ready for exam."
          : "No schedule data found.";
    });
  }

  Future<void> _removeCurrentExcel() async {
    bool? confirm = await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Clear Database?"),
          content: Text("This will delete the Schedule AND Attendance Logs.\n\nAre you sure?"),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text("Cancel")),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text("DELETE ALL", style: TextStyle(color: Colors.red))),
          ],
        )
    );

    if (confirm == true) {
      setState(() { _isLoading = true; });
      await DatabaseHelper().resetDatabase();
      await _refreshStats();
      setState(() { _isLoading = false; _status = "Database Cleared."; });
    }
  }

  Future<void> _pickAndUploadExcel() async {
    try {
      if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.clearTemporaryFiles();
      }

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        allowMultiple: false,
      );

      if (result != null) {
        setState(() { _isLoading = true; _status = "Parsing Excel..."; });

        List<int>? fileBytes;
        if (result.files.single.bytes != null) {
          fileBytes = result.files.single.bytes;
        } else if (result.files.single.path != null) {
          File file = File(result.files.single.path!);
          fileBytes = await file.readAsBytes();
        }

        if (fileBytes == null) throw Exception("Cannot read file.");

        var excel = Excel.decodeBytes(fileBytes);
        await DatabaseHelper().resetDatabase();

        int importedCount = 0;
        for (var table in excel.tables.keys) {
          var sheet = excel.tables[table];
          if (sheet != null) {
            for (int i = 0; i < sheet.rows.length; i++) {
              var row = sheet.rows[i];
              if (i == 0) continue;
              if (row.length < 3) continue;

              var colId = row[0]?.value.toString();
              var colName = row[1]?.value.toString();
              var colHall = row[2]?.value.toString();

              if (colId == null || colName == null || colHall == null) continue;
              if (colName.toLowerCase() == "name") continue;

              await DatabaseHelper().insertDailyAllotment(colId, colName, colHall);
              importedCount++;
            }
          }
        }
        await _refreshStats();
        setState(() { _isLoading = false; _status = "Successfully imported $importedCount records."; });
      }
    } catch (e) {
      setState(() { _isLoading = false; _status = "Error: $e"; });
      _showErrorDialog(e.toString());
    }
  }

  Future<void> _exportLog() async {
    try {
      setState(() { _isLoading = true; _status = "Exporting CSV..."; });
      List<Map<String, dynamic>> logs = await DatabaseHelper().getAllLogs();

      if (logs.isEmpty) {
        setState(() { _isLoading = false; _status = "No attendance data to export."; });
        return;
      }

      StringBuffer csvBuffer = StringBuffer();
      csvBuffer.writeln("Staff ID,Staff Name,Hall No,Time In");

      for (var log in logs) {
        String formattedTime = log['timestamp'];
        try {
          DateTime dt = DateTime.parse(log['timestamp']);
          String period = dt.hour >= 12 ? "PM" : "AM";
          int hour = dt.hour % 12;
          if (hour == 0) hour = 12;
          formattedTime = "${dt.day}/${dt.month} ${hour}:${dt.minute.toString().padLeft(2,'0')} $period";
        } catch (e) {}

        csvBuffer.writeln("${log['staff_id']},${log['staff_name']},${log['hall_no']},$formattedTime");
      }

      // Check Permissions before saving (Required for Android 10 and below mostly)
      if (Platform.isAndroid || Platform.isIOS) {
        if (await Permission.storage.request().isGranted || await Permission.manageExternalStorage.request().isGranted) {
          // Mobile Save Logic
          Directory? directory = await getExternalStorageDirectory();
          String newPath = "";
          List<String> paths = directory!.path.split("/");
          for (int x = 1; x < paths.length; x++) {
            String folder = paths[x];
            if (folder != "Android") newPath += "/" + folder;
            else break;
          }
          newPath = newPath + "/Download";
          directory = Directory(newPath);
          if (!await directory.exists()) directory = await getExternalStorageDirectory();

          String datePart = DateTime.now().toString().split(' ')[0];
          File file = File("${directory!.path}/Attendance_Log_$datePart.csv");
          await file.writeAsString(csvBuffer.toString());

          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exported to Downloads!"), backgroundColor: Colors.teal));
        }
      } else {
        // Desktop Save Logic (Simplification for example)
        Directory directory = await getApplicationDocumentsDirectory();
        String datePart = DateTime.now().toString().split(' ')[0];
        File file = File("${directory.path}/Attendance_Log_$datePart.csv");
        await file.writeAsString(csvBuffer.toString());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exported to Documents folder!"), backgroundColor: Colors.teal));
      }

      setState(() { _isLoading = false; _status = "Export Successful"; });

    } catch (e) {
      setState(() { _isLoading = false; _status = "Export Failed: $e"; });
    }
  }

  void _showErrorDialog(String error) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Error"),
          content: Text(error),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text("OK"))],
        ));
  }

  // --- UI SECTION ---

  @override
  Widget build(BuildContext context) {
    // Define Theme Colors
    final primaryColor = Color(0xFF4F46E5); // Modern Indigo
    final secondaryColor = Color(0xFFEEF2FF); // Light Indigo BG
    final accentColor = Color(0xFF10B981); // Emerald Green for Success

    return Scaffold(
      backgroundColor: Colors.grey[50], // Soft off-white background
      body: Column(
        children: [
          // 1. TOP HEADER (Gradient & Stats)
          Container(
            padding: EdgeInsets.only(top: 60, left: 20, right: 20, bottom: 30),
            decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [primaryColor, Color(0xFF818CF8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(30),
                  bottomRight: Radius.circular(30),
                ),
                boxShadow: [
                  BoxShadow(color: Colors.indigo.withOpacity(0.3), blurRadius: 15, offset: Offset(0, 10))
                ]
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Exam Control", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                    Icon(Icons.admin_panel_settings, color: Colors.white70),
                  ],
                ),
                SizedBox(height: 30),
                Text("TOTAL CANDIDATES", style: TextStyle(color: Colors.indigo[100], fontSize: 12, letterSpacing: 1.5)),
                SizedBox(height: 5),
                Text("$_recordCount", style: TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w900)),
                SizedBox(height: 10),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20)
                  ),
                  child: Text(_status, style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          ),

          // 2. LOADING INDICATOR
          if (_isLoading)
            LinearProgressIndicator(color: accentColor, backgroundColor: secondaryColor),

          // 3. ACTION GRID
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(20),
              children: [
                Text("Quick Actions", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                SizedBox(height: 15),

                _buildActionCard(
                    icon: Icons.upload_file,
                    color: Colors.blueAccent,
                    title: "Import Schedule",
                    subtitle: "Upload XLSX file (ID, Name, Hall)",
                    onTap: _pickAndUploadExcel
                ),

                SizedBox(height: 15),

                _buildActionCard(
                    icon: Icons.download_rounded,
                    color: Colors.teal,
                    title: "Export Logs",
                    subtitle: "Download attendance CSV report",
                    onTap: _exportLog
                ),

                SizedBox(height: 15),

                _buildActionCard(
                    icon: Icons.delete_outline,
                    color: Colors.redAccent,
                    title: "Reset Database",
                    subtitle: "Clear all data and start fresh",
                    onTap: _removeCurrentExcel,
                    isDestructive: true
                ),
              ],
            ),
          ),

          // 4. START EXAM BUTTON (Bottom Pinned)
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton.icon(
                onPressed: _recordCount > 0
                    ? () => Navigator.push(context, MaterialPageRoute(builder: (context) => ScannerScreen()))
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black87, // High contrast
                  foregroundColor: Colors.white,
                  elevation: 5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  shadowColor: Colors.black45,
                ),
                icon: Icon(Icons.qr_code_scanner, size: 28),
                label: Text("START SCAN MODE", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- HELPER WIDGET FOR CARDS ---
  Widget _buildActionCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false
  }) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.grey.withOpacity(0.08), blurRadius: 10, offset: Offset(0, 4))
          ]
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDestructive ? Colors.red[50] : color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[900])),
                      SizedBox(height: 4),
                      Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey[300]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}