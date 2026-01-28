import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'database_helper.dart';

class ScannerScreen extends StatefulWidget {
  @override
  _ScannerScreenState createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  String _message = "Starting System...";
  Color _bgColor = Colors.white;
  String? _hallDisplay;
  bool _isProcessing = false;

  Process? _pythonProcess;
  MobileScannerController? _mobileController;
  final FocusNode _keyboardFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _initializeScanner();
  }

  void _initializeScanner() {
    if (Platform.isWindows) {
      _startPythonScanner();
    } else {
      _mobileController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        returnImage: false,
      );
    }
  }

  Future<void> _checkPermissions() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await Permission.camera.request();
    }
  }

  void _stopAllScanners() {
    if (Platform.isWindows) {
      _pythonProcess?.kill();
      _pythonProcess = null;
    } else {
      _mobileController?.stop();
    }
  }

  @override
  void dispose() {
    _stopAllScanners();
    _mobileController?.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  // --- LOGGING ---
  Future<void> _log(String text) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/camera_debug_log.txt');
      await file.writeAsString("${DateTime.now()}: $text\n", mode: FileMode.append);
    } catch (e) {
      print("Log Error: $e");
    }
  }

  // --- SCANNER ENGINE ---
  void _startPythonScanner() async {
    _pythonProcess?.kill();
    if (!mounted) return;

    setState(() {
      _message = "Launching Camera...";
      _isProcessing = false;
    });

    try {
      String exePath = Platform.resolvedExecutable;
      String dir = File(exePath).parent.path;
      String scannerExePath = "$dir\\scanner.exe";

      if (await File(scannerExePath).exists()) {
        _pythonProcess = await Process.start(scannerExePath, []);
      } else {
        _pythonProcess = await Process.start('python', ['scanner.py']);
      }

      _pythonProcess!.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains("CAMERA_READY")) {
          if (mounted) setState(() { _message = "Camera Active\nScanning for IDs..."; });
        } else if (data.contains("QR_DATA:")) {
          String cleanCode = data.split("QR_DATA:")[1].trim();
          _handleCodeFound(cleanCode);
        }
      });

      _pythonProcess!.stderr.transform(utf8.decoder).listen((data) => _log("STDERR: $data"));

      _pythonProcess!.exitCode.then((_) {
        if (mounted && !_isProcessing && _hallDisplay == null) {
          setState(() => _message = "Camera Window Closed. Relaunch required.");
        }
      });

    } catch (e) {
      if (mounted) _showErrorDialog("Failed to launch scanner.\n\nError: $e");
    }
  }

  void _triggerNextScan() {
    _isProcessing = false;
    _initializeScanner();

    setState(() {
      _bgColor = Colors.white;
      _hallDisplay = null;
      _message = Platform.isWindows ? "Camera Active\nScanning..." : "Ready to Scan";
    });
    FocusScope.of(context).requestFocus(_keyboardFocus);
  }

  // --- CORE LOGIC ---
  void _handleCodeFound(String rawCode) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _message = "Checking Database...";
    });

    _stopAllScanners();

    try {
      String staffId = rawCode;
      try {
        Map<String, dynamic> data = jsonDecode(rawCode);
        staffId = data['id'] ?? data['n'] ?? rawCode;
      } catch (e) {}
      staffId = staffId.trim().toUpperCase();

      var result = await DatabaseHelper().checkStaffStatus(staffId);

      if (result != null) {
        if (result['type'] == 'LOGGED') {
          _showResult(Colors.blue, "ALREADY IN", "Hall ${result['hall_no']}: ${result['staff_name']}");
        }
        else if (result['type'] == 'SCHEDULED') {
          await DatabaseHelper().markAttendance(staffId, result['staff_name'], result['hall_no']);
          _showResult(Colors.green, "HALL ${result['hall_no']}", result['staff_name']);
        }
        else if (result['type'] == 'UNKNOWN_ID') {
          _showUnknownIdOptions(staffId);
        }
        else if (result['type'] == 'NOT_ALLOTTED') {
          _showNameMismatchDialog(staffId, result['staff_name']);
        }
      }
    } catch (e) {
      _showResult(Colors.red, "ERROR", e.toString());
    }
  }

  void _showResult(Color color, String title, String subtitle) {
    if (!mounted) return;
    setState(() { _bgColor = color; _hallDisplay = title; _message = subtitle; });
  }

  // --- DIALOG 1: NAME MISMATCH RESOLVER ---
  void _showNameMismatchDialog(String id, String masterName) async {
    List<Map<String, dynamic>> pending = await DatabaseHelper().getPendingHalls();
    TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> filteredPending = List.from(pending);

    final size = MediaQuery.of(context).size;
    final double dialogWidth = size.width > 800 ? 600 : size.width * 0.95;
    final double dialogHeight = size.height > 800 ? 500 : size.height * 0.7;

    showDialog(
        context: context, barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (context, setStateDialog) => AlertDialog(
              title: Text("Schedule Mismatch"),
              content: Container(width: dialogWidth, height: dialogHeight, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                    _showResult(Colors.green, "HALL ${filteredPending[i]['hall_no']}", masterName);
                  }),
                )))
              ])),
              actions: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  TextButton.icon(icon: Icon(Icons.swap_horiz), label: Text("REPLACE STAFF"), onPressed: () { Navigator.pop(ctx); _showSubstitutionSelector(id); }),
                  TextButton(onPressed: () { Navigator.pop(ctx); _showResult(Colors.red, "NOT ALLOTTED", "$masterName has no duty today."); }, child: Text("NO DUTY", style: TextStyle(color: Colors.red)))
                ])
              ],
            )
        )
    );
  }

  // --- DIALOG 2: UNKNOWN ID (RESPONSIVE) ---
  void _showUnknownIdOptions(String id) async {
    List<String> allNames = await DatabaseHelper().getAllAvailableNames();
    String? selectedName;
    TextEditingController manualController = TextEditingController();

    final size = MediaQuery.of(context).size;
    final double dialogWidth = size.width > 800 ? 700 : size.width * 0.95;
    final double dialogHeight = size.height > 800 ? 550 : size.height * 0.8;

    showDialog(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(
      title: Text("Unknown ID Detected", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      content: Container(
        width: dialogWidth,
        height: dialogHeight,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                decoration: BoxDecoration(color: Colors.amber[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.shade200)),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.amber[800], size: 30),
                    SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("ID: $id", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                          Text("This ID is not in the Master List.", style: TextStyle(color: Colors.amber[900])),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 30),
              Text("Option 1: Link to Existing Staff", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.indigo)),
              SizedBox(height: 10),
              Autocomplete<String>(
                optionsBuilder: (v) => v.text == '' ? const Iterable<String>.empty() : allNames.where((opt) => opt.toLowerCase().contains(v.text.toLowerCase())),
                onSelected: (s) => selectedName = s,
                fieldViewBuilder: (ctx, ctrl, focus, submit) => TextField(controller: ctrl, focusNode: focus, decoration: InputDecoration(hintText: "Link to Name", prefixIcon: Icon(Icons.link), border: OutlineInputBorder(), filled: true, fillColor: Colors.grey[50])),
              ),
              SizedBox(height: 20),
              Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text("OR", style: TextStyle(color: Colors.grey))), Expanded(child: Divider())]),
              SizedBox(height: 20),
              Text("Option 2: Register New Name", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal)),
              SizedBox(height: 10),
              TextField(controller: manualController, decoration: InputDecoration(hintText: "Enter Full Name", prefixIcon: Icon(Icons.person_add), border: OutlineInputBorder(), filled: true, fillColor: Colors.grey[50]), onChanged: (v) => selectedName = null),

              SizedBox(height: 30),
              size.width < 500
                  ? Column(
                  children: [
                    SizedBox(width: double.infinity, child: ElevatedButton.icon(icon: Icon(Icons.swap_horiz), label: Text("REPLACE ABSENT STAFF"), style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(vertical: 15)), onPressed: () { Navigator.pop(ctx); _showSubstitutionSelector(id); })),
                    SizedBox(height: 10),
                    SizedBox(width: double.infinity, child: ElevatedButton.icon(icon: Icon(Icons.save), label: Text("LINK & SAVE"), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(vertical: 15)), onPressed: () async {
                      String name = manualController.text.isNotEmpty ? manualController.text : (selectedName ?? "");
                      if (name.isNotEmpty) { await DatabaseHelper().linkStaff(id, name); Navigator.pop(ctx); _isProcessing = false; _handleCodeFound(id); }
                    })),
                  ]
              )
                  : Row(
                children: [
                  Expanded(child: ElevatedButton.icon(icon: Icon(Icons.swap_horiz), label: Text("REPLACE ABSENT STAFF"), style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(vertical: 20)), onPressed: () { Navigator.pop(ctx); _showSubstitutionSelector(id); })),
                  SizedBox(width: 20),
                  Expanded(child: ElevatedButton.icon(icon: Icon(Icons.save), label: Text("LINK & SAVE"), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(vertical: 20)), onPressed: () async {
                    String name = manualController.text.isNotEmpty ? manualController.text : (selectedName ?? "");
                    if (name.isNotEmpty) { await DatabaseHelper().linkStaff(id, name); Navigator.pop(ctx); _isProcessing = false; _handleCodeFound(id); }
                  })),
                ],
              )
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () { Navigator.pop(ctx); _triggerNextScan(); }, child: Text("Cancel", style: TextStyle(fontSize: 16)))
      ],
    ));
  }

  // --- DIALOG 3: SUBSTITUTION (RESPONSIVE) ---
  void _showSubstitutionSelector(String id) async {
    List<Map<String, dynamic>> pending = await DatabaseHelper().getPendingHalls();
    TextEditingController nameCtrl = TextEditingController();
    TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> filteredPending = List.from(pending);

    final size = MediaQuery.of(context).size;
    final double dialogWidth = size.width > 800 ? 700 : size.width * 0.95;
    final double dialogHeight = size.height > 800 ? 600 : size.height * 0.8;

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (context, setStateDialog) => AlertDialog(
                title: Text("Replace Absent Staff", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                content: Container(
                    width: dialogWidth,
                    height: dialogHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("1. Enter New Staff Name", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700])),
                        SizedBox(height: 10),
                        TextField(
                            controller: nameCtrl,
                            style: TextStyle(fontSize: 18),
                            decoration: InputDecoration(
                                hintText: "Your Name",
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.person_add, color: Colors.indigo),
                                filled: true,
                                fillColor: Colors.grey[50]
                            )
                        ),
                        SizedBox(height: 25), Divider(thickness: 1), SizedBox(height: 15),
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
                        Expanded(
                            child: ListView.builder(
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
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white, padding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
                                        onPressed: () async {
                                          if (nameCtrl.text.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Enter YOUR name first!"))); return; }
                                          await DatabaseHelper().substituteAndLink(id, nameCtrl.text, filteredPending[i]['hall_no']);
                                          Navigator.pop(ctx);
                                          _showResult(Colors.orange, "REPLACED", "Hall ${filteredPending[i]['hall_no']}");
                                        }
                                    ),
                                  ),
                                )
                            )
                        )
                      ],
                    )
                ),
                actionsPadding: EdgeInsets.only(right: 25, bottom: 20),
                actions: [
                  TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _triggerNextScan();
                      },
                      child: Text("Cancel", style: TextStyle(fontSize: 16, color: Colors.indigo, fontWeight: FontWeight.bold))
                  )
                ]
            )
        )
    );
  }

  void _showErrorDialog(String error) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text("Error"), content: Text(error), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text("OK"))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKey: (event) {
        if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.space) {
          if (_hallDisplay != null) _triggerNextScan();
        }
      },
      child: Scaffold(
        backgroundColor: _bgColor,
        appBar: _hallDisplay == null ? AppBar(title: Text("Kiosk Mode")) : null,
        body: _hallDisplay != null
            ? _buildResultUI()
            : (Platform.isWindows ? _buildWindowsUI() : _buildMobileUI()),
      ),
    );
  }

  Widget _buildResultUI() {
    final size = MediaQuery.of(context).size;
    final double titleSize = size.width > 600 ? 80 : 50;

    return InkWell(
      onTap: _triggerNextScan,
      child: Center(child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 100),
            SizedBox(height: 20),
            Text(_hallDisplay!, textAlign: TextAlign.center, style: TextStyle(fontSize: titleSize, color: Colors.white, fontWeight: FontWeight.bold)),
            SizedBox(height: 20),
            Text(_message, textAlign: TextAlign.center, style: TextStyle(fontSize: 32, color: Colors.white70)),
            SizedBox(height: 50),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(20)),
              child: Text("Press SPACE BAR for Next", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            )
          ],
        ),
      )),
    );
  }

  Widget _buildMobileUI() {
    return Column(children: [
      Expanded(flex: 2, child: MobileScanner(controller: _mobileController!, onDetect: (c) => _handleCodeFound(c.barcodes.first.rawValue!))),
      Expanded(flex: 1, child: Center(child: Text(_message)))
    ]);
  }

  Widget _buildWindowsUI() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.monitor, size: 100, color: Colors.indigo),
        SizedBox(height: 30),
        Text("SYSTEM ACTIVE", style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 2)),
        SizedBox(height: 20),
        Text(_message, style: TextStyle(fontSize: 18, color: Colors.grey)),
        SizedBox(height: 40),
        ElevatedButton(onPressed: _startPythonScanner, child: Text("Relaunch Camera"))
      ]),
    );
  }
}