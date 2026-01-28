import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
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

  Future<void> _refreshStats() async {
    final count = await DatabaseHelper().getPendingCount();
    setState(() {
      _recordCount = count;
      _status = _recordCount > 0 ? "Ready for Exam" : "No Daily Schedule Found";
    });
  }

  String _getCellValue(var cell) {
    if (cell == null) return "";
    return cell.toString().trim();
  }

  // --- 1. MASTER LIST UPLOADER ---
  Future<void> _uploadMasterList() async {
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
        setState(() { _isLoading = true; _status = "Parsing Master List..."; });

        var bytes = File(result.files.single.path!).readAsBytesSync();
        var decoder = SpreadsheetDecoder.decodeBytes(bytes);

        await DatabaseHelper().clearMasterList();
        int imported = 0;

        for (var table in decoder.tables.keys) {
          var sheet = decoder.tables[table]!;
          int headerRow = -1;
          int idCol = -1;
          int nameCol = -1;

          int maxRows = sheet.rows.length < 20 ? sheet.rows.length : 20;
          for (int i = 0; i < maxRows; i++) {
            var row = sheet.rows[i];
            for (int j = 0; j < row.length; j++) {
              String cell = _getCellValue(row[j]).toLowerCase();
              if (cell.contains("id") || cell.contains("emp")) idCol = j;
              if (cell.contains("name") || cell.contains("faculty")) nameCol = j;
            }
            if (idCol != -1 && nameCol != -1) { headerRow = i; break; }
          }

          if (headerRow == -1) { headerRow = 0; idCol = 0; nameCol = 1; }

          for (int i = headerRow + 1; i < sheet.rows.length; i++) {
            var row = sheet.rows[i];
            if (row.length <= nameCol) continue;

            String id = (row.length > idCol) ? _getCellValue(row[idCol]) : "";
            String name = _getCellValue(row[nameCol]);

            if (id.isEmpty || name.isEmpty) continue;
            if (name.toLowerCase().contains("name") && id.toLowerCase().contains("id")) continue;

            await DatabaseHelper().insertMasterStaff(id, name);
            imported++;
          }
        }

        setState(() { _isLoading = false; _status = "Master List: $imported Staff"; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Master List Updated: $imported records"), backgroundColor: Colors.green));
      }
    } catch (e) {
      setState(() { _isLoading = false; _status = "Error: $e"; });
      _showErrorDialog("Master List Error: $e");
    }
  }

  // --- 2. DAILY SCHEDULE UPLOADER ---
  Future<void> _uploadDailySchedule() async {
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
        setState(() { _isLoading = true; _status = "Analyzing Schedule..."; });

        var bytes = File(result.files.single.path!).readAsBytesSync();
        var decoder = SpreadsheetDecoder.decodeBytes(bytes);

        await DatabaseHelper().clearDailySchedule();
        int imported = 0;

        for (var table in decoder.tables.keys) {
          var sheet = decoder.tables[table]!;
          int headerRowIndex = -1;
          int nameColIndex = -1;
          int hallColIndex = -1;

          for (int i = 0; i < sheet.rows.length; i++) {
            var row = sheet.rows[i];
            for (int j = 0; j < row.length; j++) {
              String cell = _getCellValue(row[j]).toLowerCase();
              if (cell.contains("name") || cell.contains("faculty")) { headerRowIndex = i; nameColIndex = j; }
              if (cell.contains("hall") || cell.contains("room")) { hallColIndex = j; }
            }
            if (headerRowIndex != -1 && nameColIndex != -1 && hallColIndex != -1) break;
          }

          if (headerRowIndex == -1) continue;

          String lastHall = "";

          for (int i = headerRowIndex + 1; i < sheet.rows.length; i++) {
            var row = sheet.rows[i];
            if (row.length <= nameColIndex) continue;

            String name = _getCellValue(row[nameColIndex]);
            String hall = (row.length > hallColIndex) ? _getCellValue(row[hallColIndex]) : "";

            if (name.isEmpty || name.toLowerCase() == "null") continue;
            if (hall.isEmpty || hall.toLowerCase() == "null") hall = lastHall; else lastHall = hall;

            if (hall.isNotEmpty) {
              await DatabaseHelper().insertDailyAllotment(name, hall);
              imported++;
            }
          }
        }

        await _refreshStats();
        setState(() { _isLoading = false; _status = "Imported $imported Allotments"; });
      }
    } catch (e) {
      setState(() { _isLoading = false; _status = "Error: $e"; });
      _showErrorDialog("Schedule Error: $e");
    }
  }

  // --- 3. EXPORT LOGIC ---
  Future<void> _exportLog() async {
    try {
      TimeOfDay? cutoffTime = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: 8, minute: 0),
          helpText: "SELECT LATE ENTRY CUTOFF",
          builder: (context, child) {
            return Theme(data: ThemeData.light().copyWith(colorScheme: ColorScheme.light(primary: Colors.indigo)), child: child!);
          }
      );

      if (cutoffTime == null) return;

      setState(() { _isLoading = true; _status = "Exporting CSV..."; });
      List<Map<String, dynamic>> logs = await DatabaseHelper().getAllLogs();

      if (logs.isEmpty) {
        setState(() { _isLoading = false; _status = "No data to export."; });
        return;
      }

      StringBuffer csvBuffer = StringBuffer();
      csvBuffer.writeln("Staff ID,Staff Name,Hall No,Time In,Entry Status");

      for (var log in logs) {
        String formattedTime = log['timestamp'];
        String status = "ON TIME";

        try {
          DateTime dt = DateTime.parse(log['timestamp']);
          DateTime cutoffDateTime = DateTime(dt.year, dt.month, dt.day, cutoffTime.hour, cutoffTime.minute, 0);
          if (dt.isAfter(cutoffDateTime)) {
            status = "LATE ENTRY";
          }
          String period = dt.hour >= 12 ? "PM" : "AM";
          int hour = dt.hour % 12;
          if (hour == 0) hour = 12;
          formattedTime = "${dt.day}/${dt.month} ${hour}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')} $period";
        } catch (e) {}

        csvBuffer.writeln("${log['staff_id']},${log['staff_name']},${log['hall_no']},$formattedTime,$status");
      }

      String fileName = "Attendance Log.csv";

      if (Platform.isAndroid || Platform.isIOS) {
        if (await Permission.storage.request().isGranted || await Permission.manageExternalStorage.request().isGranted) {
          Directory? directory = await getExternalStorageDirectory();
          String newPath = "";
          List<String> paths = directory!.path.split("/");
          for (int x = 1; x < paths.length; x++) {
            String folder = paths[x];
            if (folder != "Android") newPath += "/" + folder; else break;
          }
          newPath = newPath + "/Download";
          directory = Directory(newPath);
          if (!await directory.exists()) directory = await getExternalStorageDirectory();

          File file = File("${directory!.path}/$fileName");
          await file.writeAsString(csvBuffer.toString());
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Saved to Downloads!"), backgroundColor: Colors.teal));
        }
      } else {
        Directory directory = await getApplicationDocumentsDirectory();
        File file = File("${directory.path}/$fileName");
        await file.writeAsString(csvBuffer.toString());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exported to Documents!"), backgroundColor: Colors.teal));
      }
      setState(() { _isLoading = false; _status = "Export Successful"; });
    } catch (e) {
      setState(() { _isLoading = false; _status = "Export Failed: $e"; });
    }
  }

  // --- 4. RESET DATABASE ---
  Future<void> _resetDatabase() async {
    bool? confirm = await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("FULL RESET?"),
          content: Text("This will delete:\n1. The Daily Schedule\n2. All Attendance Logs\n\nThe Master List will be KEPT.\n\nAre you sure?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text("Cancel")),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text("RESET EVERYTHING", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
          ],
        )
    );

    if (confirm == true) {
      setState(() { _isLoading = true; });
      await DatabaseHelper().resetDatabase();
      await _refreshStats();
      setState(() { _isLoading = false; _status = "System Reset Complete."; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Database Reset Successfully"), backgroundColor: Colors.red));
    }
  }

  // ==========================================================
  //  5. MANUAL ENTRY SYSTEM (UPDATED WITH RESOLUTION LOGIC)
  // ==========================================================

  void _showManualEntryDialog() {
    TextEditingController _idController = TextEditingController();
    FocusNode _focusNode = FocusNode();

    showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: Text("Manual ID Entry", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                content: Container(
                  width: 700,
                  height: 250,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("Enter Employee ID manually. The window will refresh after entry.", style: TextStyle(fontSize: 16, color: Colors.grey)),
                      SizedBox(height: 30),
                      TextField(
                        controller: _idController,
                        focusNode: _focusNode,
                        autofocus: true,
                        style: TextStyle(fontSize: 32, letterSpacing: 3, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                            hintText: "TYPE ID HERE",
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
                            prefixIcon: Icon(Icons.keyboard, size: 40),
                            contentPadding: EdgeInsets.symmetric(vertical: 25, horizontal: 20)
                        ),
                        onSubmitted: (_) => _processManualEntry(ctx, _idController, _focusNode),
                      ),
                    ],
                  ),
                ),
                actionsPadding: EdgeInsets.all(25),
                actions: [
                  TextButton(onPressed: ()=>Navigator.pop(ctx), child: Text("Close", style: TextStyle(fontSize: 20, color: Colors.grey))),
                  ElevatedButton(
                      style: ElevatedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 40, vertical: 20), backgroundColor: Colors.indigo, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      onPressed: () => _processManualEntry(ctx, _idController, _focusNode),
                      child: Text("MARK PRESENT", style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold))
                  )
                ],
              );
            }
        )
    );
  }

  void _processManualEntry(BuildContext ctx, TextEditingController controller, FocusNode focusNode) async {
    String id = controller.text.trim();
    if (id.isEmpty) return;

    try {
      var result = await DatabaseHelper().checkStaffStatus(id);

      if (result != null) {
        if (result['type'] == 'SCHEDULED') {
          await DatabaseHelper().markAttendance(id, result['staff_name'], result['hall_no']);
          await _showResultAndReopen("HALL ${result['hall_no']}", result['staff_name'], Colors.green);

        } else if (result['type'] == 'LOGGED') {
          await _showResultAndReopen("ALREADY IN", "${result['staff_name']} is in Hall ${result['hall_no']}", Colors.blue);

        } else if (result['type'] == 'UNKNOWN_ID') {
          Navigator.pop(ctx); // Close Manual Dialog to show Unknown Dialog
          _showUnknownIdOptions(id);

        } else if (result['type'] == 'NOT_ALLOTTED') {
          Navigator.pop(ctx); // Close Manual Dialog to show Mismatch Dialog
          _showNameMismatchDialog(id, result['staff_name']);
        }
      }
    } catch (e) {
      _showErrorDialog("Error: $e");
    }

    // Clear text and refocus for next entry (If not popped)
    controller.clear();
    focusNode.requestFocus();
  }

  // --- HELPER: Shows Result, then Re-opens Manual Entry ---
  Future<void> _showResultAndReopen(String title, String subtitle, Color color) async {
    await Navigator.push(context, MaterialPageRoute(builder: (c) => FullScreenResultScreen(title: title, subtitle: subtitle, bgColor: color)));
    // No need to reopen manually if we didn't close the dialog, but if we did (for Unknown/Mismatch resolution), the resolution functions handle reopening.
  }

  // --- RESOLUTION DIALOG 1: UNKNOWN ID (REVAMPED UI) ---
  void _showUnknownIdOptions(String id) async {
    List<String> allNames = await DatabaseHelper().getAllAvailableNames();
    String? selectedName;
    TextEditingController manualController = TextEditingController();

    showDialog(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(
      title: Text("Unknown ID Detected", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      content: Container(
        width: 700, // WIDER
        height: 550, // TALLER
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Warning Banner
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              decoration: BoxDecoration(color: Colors.amber[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.shade200)),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber[800], size: 30),
                  SizedBox(width: 15),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("ID: $id", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                      Text("This ID is not in the Master List.", style: TextStyle(color: Colors.amber[900])),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: 30),

            // Option 1
            Text("Option 1: Link to Existing Staff", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.indigo)),
            SizedBox(height: 10),
            Autocomplete<String>(
              optionsBuilder: (v) => v.text == '' ? const Iterable<String>.empty() : allNames.where((opt) => opt.toLowerCase().contains(v.text.toLowerCase())),
              onSelected: (s) => selectedName = s,
              fieldViewBuilder: (ctx, ctrl, focus, submit) => TextField(controller: ctrl, focusNode: focus, decoration: InputDecoration(hintText: "Search Name to Link...", prefixIcon: Icon(Icons.link), border: OutlineInputBorder(), filled: true, fillColor: Colors.grey[50])),
            ),

            SizedBox(height: 20),
            Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text("OR", style: TextStyle(color: Colors.grey))), Expanded(child: Divider())]),
            SizedBox(height: 20),

            // Option 2
            Text("Option 2: Register New Name", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal)),
            SizedBox(height: 10),
            TextField(controller: manualController, decoration: InputDecoration(hintText: "Enter Full Name", prefixIcon: Icon(Icons.person_add), border: OutlineInputBorder(), filled: true, fillColor: Colors.grey[50]), onChanged: (v) => selectedName = null),

            Spacer(),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                      icon: Icon(Icons.swap_horiz),
                      label: Text("REPLACE ABSENT STAFF"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(vertical: 20)),
                      onPressed: () { Navigator.pop(ctx); _showSubstitutionSelector(id); }
                  ),
                ),
                SizedBox(width: 20),
                Expanded(
                  child: ElevatedButton.icon(
                      icon: Icon(Icons.save),
                      label: Text("LINK & SAVE"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(vertical: 20)),
                      onPressed: () async {
                        String name = manualController.text.isNotEmpty ? manualController.text : (selectedName ?? "");
                        if (name.isNotEmpty) {
                          await DatabaseHelper().linkStaff(id, name);
                          Navigator.pop(ctx);
                          // Re-process manually by reopening the dialog
                          _showManualEntryDialog();
                        }
                      }
                  ),
                ),
              ],
            )
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () { Navigator.pop(ctx); _showManualEntryDialog(); }, child: Text("Cancel", style: TextStyle(fontSize: 16)))
      ],
    ));
  }

  // --- RESOLUTION DIALOG 2: MISMATCH ---
  void _showNameMismatchDialog(String id, String masterName) async {
    List<Map<String, dynamic>> pending = await DatabaseHelper().getPendingHalls();
    TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> filteredPending = List.from(pending);

    showDialog(
        context: context, barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (context, setStateDialog) => AlertDialog(
              title: Text("Schedule Mismatch"),
              content: Container(width: 500, height: 500, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(padding: EdgeInsets.all(10), color: Colors.orange[50], child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text("Found in Master List:", style: TextStyle(color: Colors.grey[700], fontSize: 12)),
                  Text(masterName, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 5), Text("Status: Not found in Daily Schedule", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                ])),
                SizedBox(height: 15), Text("Is this staff listed differently?", style: TextStyle(fontWeight: FontWeight.bold)),
                TextField(controller: searchCtrl, decoration: InputDecoration(hintText: "Search Schedule...", prefixIcon: Icon(Icons.search)), onChanged: (val) {
                  setStateDialog(() { filteredPending = pending.where((row) => row['staff_name'].toString().toLowerCase().contains(val.toLowerCase()) || row['hall_no'].toString().contains(val)).toList(); });
                }),
                Expanded(child: ListView.separated(separatorBuilder: (c,i)=>Divider(), itemCount: filteredPending.length, itemBuilder: (c, i) => ListTile(
                  title: Text(filteredPending[i]['staff_name']), subtitle: Text("Hall: ${filteredPending[i]['hall_no']}"),
                  trailing: ElevatedButton(child: Text("LINK"), onPressed: () async {
                    await DatabaseHelper().addAlias(masterName, filteredPending[i]['staff_name']);
                    await DatabaseHelper().substituteAndLink(id, masterName, filteredPending[i]['hall_no']);
                    Navigator.pop(ctx);
                    await _showResultAndReopen("HALL ${filteredPending[i]['hall_no']}", masterName, Colors.green);
                    _showManualEntryDialog();
                  }),
                )))
              ])),
              actions: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  TextButton.icon(icon: Icon(Icons.swap_horiz), label: Text("REPLACE STAFF"), onPressed: () { Navigator.pop(ctx); _showSubstitutionSelector(id); }),
                  TextButton(onPressed: () { Navigator.pop(ctx); _showResultAndReopen("NOT ALLOTTED", "No duty today.", Colors.red); _showManualEntryDialog(); }, child: Text("NO DUTY", style: TextStyle(color: Colors.red)))
                ])
              ],
            )
        )
    );
  }

  // --- RESOLUTION DIALOG 3: SUBSTITUTE (REVAMPED UI) ---
  void _showSubstitutionSelector(String id) async {
    // 1. Fetch absent staff
    List<Map<String, dynamic>> pending = await DatabaseHelper().getPendingHalls();

    // 2. Controllers
    TextEditingController nameCtrl = TextEditingController();
    TextEditingController searchCtrl = TextEditingController();

    // 3. Filterable list
    List<Map<String, dynamic>> filteredPending = List.from(pending);

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (context, setStateDialog) => AlertDialog(
                title: Text("Replace Absent Staff", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                content: Container(
                    width: 700, // Wide like the Manual Entry screen
                    height: 600, // Tall enough for the list
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // SECTION 1: YOUR NAME
                        Text("1. Enter New Staff Name", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700])),
                        SizedBox(height: 10),
                        TextField(
                            controller: nameCtrl,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            decoration: InputDecoration(
                                hintText: "Your Name",
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.person_add, color: Colors.indigo),
                                filled: true,
                                fillColor: Colors.grey[50]
                            )
                        ),

                        SizedBox(height: 25), Divider(thickness: 1), SizedBox(height: 15),

                        // SECTION 2: SEARCH
                        Text("2. Select who you are replacing", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700])),
                        SizedBox(height: 10),
                        TextField(
                          controller: searchCtrl,
                          decoration: InputDecoration(
                              hintText: "Search Name or Hall...",
                              prefixIcon: Icon(Icons.search),
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.all(15)
                          ),
                          onChanged: (val) {
                            setStateDialog(() {
                              filteredPending = pending.where((row) =>
                              row['staff_name'].toString().toLowerCase().contains(val.toLowerCase()) ||
                                  row['hall_no'].toString().toLowerCase().contains(val.toLowerCase())
                              ).toList();
                            });
                          },
                        ),
                        SizedBox(height: 15),

                        // SECTION 3: LIST
                        Expanded(
                            child: filteredPending.isEmpty
                                ? Center(child: Text("No absent staff found matching '${searchCtrl.text}'", style: TextStyle(color: Colors.grey)))
                                : ListView.builder(
                                itemCount: filteredPending.length,
                                itemBuilder: (c, i) => Card(
                                  elevation: 3,
                                  margin: EdgeInsets.only(bottom: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  child: ListTile(
                                    contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                    leading: CircleAvatar(
                                        radius: 25,
                                        backgroundColor: Colors.red[50],
                                        child: Text(
                                            "${filteredPending[i]['hall_no']}",
                                            style: TextStyle(color: Colors.red[800], fontWeight: FontWeight.bold, fontSize: 12)
                                        )
                                    ),
                                    title: Text("Hall ${filteredPending[i]['hall_no']}", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                                    subtitle: RichText(
                                      text: TextSpan(
                                          style: TextStyle(color: Colors.black87, fontSize: 14),
                                          children: [
                                            TextSpan(text: "Replacing: "),
                                            TextSpan(text: filteredPending[i]['staff_name'], style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red[700])),
                                          ]
                                      ),
                                    ),
                                    trailing: ElevatedButton.icon(
                                        icon: Icon(Icons.swap_horiz, size: 18),
                                        label: Text("REPLACE"),
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                                        onPressed: () async {
                                          if (nameCtrl.text.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Enter YOUR name first!"))); return; }

                                          // PERFORM SWAP
                                          await DatabaseHelper().substituteAndLink(id, nameCtrl.text, filteredPending[i]['hall_no']);

                                          Navigator.pop(ctx); // Close Dialog

                                          // SHOW RESULT
                                          await _showResultAndReopen("REPLACED", "Hall ${filteredPending[i]['hall_no']}", Colors.orange);

                                          // RE-OPEN MANUAL ENTRY
                                          _showManualEntryDialog();
                                        }
                                    ),
                                  ),
                                )
                            )
                        )
                      ],
                    )
                ),
                actionsPadding: EdgeInsets.all(20),
                actions: [
                  TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showManualEntryDialog(); // Go back to manual entry on cancel
                      },
                      child: Text("Cancel", style: TextStyle(fontSize: 18, color: Colors.grey))
                  )
                ]
            )
        )
    );
  }

  void _showErrorDialog(String error) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Info"),
          content: Text(error),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text("OK"))],
        ));
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Color(0xFF4F46E5);
    final secondaryColor = Color(0xFFEEF2FF);
    final accentColor = Color(0xFF10B981);

    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.only(top: 60, left: 20, right: 20, bottom: 30),
            decoration: BoxDecoration(
                gradient: LinearGradient(colors: [primaryColor, Color(0xFF818CF8)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(30), bottomRight: Radius.circular(30)),
                boxShadow: [BoxShadow(color: Colors.indigo.withOpacity(0.3), blurRadius: 15, offset: Offset(0, 10))]
            ),
            child: Column(
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text("Exam Control", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  Icon(Icons.admin_panel_settings, color: Colors.white70),
                ]),
                SizedBox(height: 30),
                Text("TOTAL CANDIDATES", style: TextStyle(color: Colors.indigo[100], fontSize: 12, letterSpacing: 1.5)),
                SizedBox(height: 5),
                Text("$_recordCount", style: TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w900)),
                SizedBox(height: 10),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
                  child: Text(_status, style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          ),
          if (_isLoading) LinearProgressIndicator(color: accentColor, backgroundColor: secondaryColor),
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(20),
              children: [
                Text("Setup", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                SizedBox(height: 15),
                _buildActionCard(icon: Icons.people_alt, color: Colors.blueGrey, title: "1. Upload Master List", subtitle: "Map IDs to Names (One time setup)", onTap: _uploadMasterList),
                SizedBox(height: 15),
                _buildActionCard(icon: Icons.calendar_today, color: Colors.blueAccent, title: "2. Upload Daily Schedule", subtitle: "Import the messy duty list Excel", onTap: _uploadDailySchedule),
                SizedBox(height: 15),
                _buildActionCard(icon: Icons.keyboard, color: Colors.purple, title: "3. Manual ID Entry", subtitle: "Type ID manually if QR is missing", onTap: _showManualEntryDialog),
                SizedBox(height: 25),
                Text("Reports", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                SizedBox(height: 15),
                _buildActionCard(icon: Icons.download_rounded, color: Colors.teal, title: "Export Logs", subtitle: "Set Late Cutoff & Save CSV", onTap: _exportLog),
                SizedBox(height: 15),
                _buildActionCard(icon: Icons.delete_outline, color: Colors.redAccent, title: "Full Reset", subtitle: "Clear Schedule & Logs", onTap: _resetDatabase, isDestructive: true),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton.icon(
                onPressed: _recordCount > 0 ? () => Navigator.push(context, MaterialPageRoute(builder: (context) => ScannerScreen())) : null,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, foregroundColor: Colors.white, elevation: 5, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                icon: Icon(Icons.qr_code_scanner, size: 28),
                label: Text("START SCAN MODE", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({required IconData icon, required Color color, required String title, required String subtitle, required VoidCallback onTap, bool isDestructive = false}) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.08), blurRadius: 10, offset: Offset(0, 4))]),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: Row(
              children: [
                Container(padding: EdgeInsets.all(12), decoration: BoxDecoration(color: isDestructive ? Colors.red[50] : color.withOpacity(0.1), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 28)),
                SizedBox(width: 20),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[900])), SizedBox(height: 4), Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500]))])),
                Icon(Icons.chevron_right, color: Colors.grey[300]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FullScreenResultScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final Color bgColor;
  const FullScreenResultScreen({required this.title, required this.subtitle, required this.bgColor});

  @override
  _FullScreenResultScreenState createState() => _FullScreenResultScreenState();
}

class _FullScreenResultScreenState extends State<FullScreenResultScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(seconds: 3), () {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.bgColor,
      body: InkWell(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 120),
              SizedBox(height: 30),
              Text(widget.title, textAlign: TextAlign.center, style: TextStyle(fontSize: 90, color: Colors.white, fontWeight: FontWeight.bold)),
              SizedBox(height: 20),
              Text(widget.subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 36, color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}