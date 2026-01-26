import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Keyboard
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
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
  final FocusNode _keyboardFocus = FocusNode(); // To capture Space Bar

  @override
  void initState() {
    super.initState();
    _checkPermissions();
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

  @override
  void dispose() {
    _mobileController?.dispose();
    _pythonProcess?.kill();
    _keyboardFocus.dispose();
    super.dispose();
  }

  // --- PYTHON LOGIC ---
  void _startPythonScanner() async {
    _pythonProcess?.kill(); // Ensure only one runs
    if (!mounted) return;
    setState(() { _message = "Launching Camera Feed..."; });

    try {
      _pythonProcess = await Process.start('python', ['scanner.py']);

      _pythonProcess!.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains("CAMERA_READY")) {
          if (mounted) setState(() { _message = "Camera Active\nScanning for IDs..."; });
        }
        else if (data.contains("QR_DATA:")) {
          String cleanCode = data.split("QR_DATA:")[1].trim();
          _handleCodeFound(cleanCode);
        }
      });
    } catch (e) {
      if (mounted) setState(() { _message = "Error: Could not launch scanner.py"; });
    }
  }

  // --- TRIGGER NEXT STUDENT ---
  void _triggerNextScan() {
    if (Platform.isWindows && _pythonProcess != null) {
      // Send "NEXT" command to Python script
      _pythonProcess!.stdin.writeln("NEXT");
    }

    setState(() {
      _isProcessing = false;
      _bgColor = Colors.white;
      _hallDisplay = null;
      _message = Platform.isWindows ? "Camera Active\nScanning..." : "Ready to Scan";
    });

    // Ensure focus returns to the page so spacebar works next time too
    FocusScope.of(context).requestFocus(_keyboardFocus);
  }

  // --- MOBILE SCANNER LOGIC ---
  void _handleMobileScan(BarcodeCapture capture) {
    if (_isProcessing) return;
    for (final barcode in capture.barcodes) {
      if (barcode.rawValue != null) {
        _handleCodeFound(barcode.rawValue!);
        break;
      }
    }
  }

  // --- HANDLE SCAN ---
  void _handleCodeFound(String rawCode) async {
    if (_isProcessing) return;

    setState(() { _isProcessing = true; _message = "Fetching Data..."; });
    // Request focus so we can capture the Space Bar immediately
    FocusScope.of(context).requestFocus(_keyboardFocus);

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
        } else {
          await DatabaseHelper().markAttendance(staffId, result['staff_name'], result['hall_no']);
          _showResult(Colors.green, "HALL ${result['hall_no']}", result['staff_name']);
        }
      } else {
        _showSubstitutionDialog(staffId);
      }
    } catch (e) {
      _showResult(Colors.red, "ERROR", e.toString());
    }
  }

  void _showResult(Color color, String title, String subtitle) {
    if (!mounted) return;
    setState(() { _bgColor = color; _hallDisplay = title; _message = subtitle; });
    // Note: No timer here anymore. User controls it via Space Bar.
  }

  void _showSubstitutionDialog(String id) async {
    var pending = await DatabaseHelper().getPendingHalls();
    TextEditingController nameCtrl = TextEditingController();

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text("Substitute Entry"),
          content: Container(
            width: 400, height: 300,
            child: Column(children: [
              Text("ID $id not in schedule."),
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: "Enter Student Name")),
              Expanded(child: ListView.builder(
                  itemCount: pending.length,
                  itemBuilder: (c, i) => ListTile(
                    title: Text("Hall ${pending[i]['hall_no']}"),
                    subtitle: Text("Absent: ${pending[i]['staff_name']}"),
                    onTap: () async {
                      await DatabaseHelper().markSubstitution(id, nameCtrl.text, pending[i]['hall_no']);
                      Navigator.pop(ctx);
                      _showResult(Colors.orange, "REPLACED", "Hall ${pending[i]['hall_no']}");
                    },
                  )
              ))
            ]),
          ),
          actions: [
            TextButton(onPressed: () {Navigator.pop(ctx); _triggerNextScan();}, child: Text("Cancel"))
          ],
        )
    );
  }

  @override
  Widget build(BuildContext context) {
    // WRAP EVERYTHING IN KEYBOARD LISTENER
    return RawKeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKey: (RawKeyEvent event) {
        if (event is RawKeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.space) {
            // Only trigger if we are currently showing a result
            if (_hallDisplay != null) {
              _triggerNextScan();
            }
          }
        }
      },
      child: Scaffold(
        backgroundColor: _bgColor,
        appBar: _hallDisplay == null ? AppBar(title: Text("Kiosk Mode")) : null, // Hide AppBar on result screen for full immersion
        body: _hallDisplay != null
            ? _buildResultUI()
            : (Platform.isWindows ? _buildWindowsUI() : _buildMobileUI()),
      ),
    );
  }

  Widget _buildResultUI() {
    return InkWell(
      onTap: _triggerNextScan, // Tap also works
      child: Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, color: Colors.white, size: 100),
          Text(_hallDisplay!, style: TextStyle(fontSize: 80, color: Colors.white, fontWeight: FontWeight.bold)),
          SizedBox(height: 20),
          Text(_message, style: TextStyle(fontSize: 32, color: Colors.white70)),
          SizedBox(height: 50),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(20)),
            child: Text("Press SPACE BAR for Next", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          )
        ],
      )),
    );
  }

  Widget _buildMobileUI() {
    return Column(children: [
      Expanded(flex: 2, child: MobileScanner(
          controller: _mobileController!,
          onDetect: _handleMobileScan
      )),
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