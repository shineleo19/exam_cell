import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'database_helper.dart';

class ScannerScreen extends StatefulWidget {
  @override
  _ScannerScreenState createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
  bool _isScanning = true;
  String _message = "Ready to Scan";
  Color _bgColor = Colors.white;
  String? _hallDisplay;

  // Controller with camera selector
  final MobileScannerController cameraController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    returnImage: false,
    facing: CameraFacing.back, // Default to back camera
    torchEnabled: false,
  );

  @override
  void initState() {
    super.initState();
    _requestStoragePermission();
  }

  Future<void> _requestStoragePermission() async {
    await [Permission.storage, Permission.manageExternalStorage, Permission.camera].request();
  }

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  // --- CAMERA SWITCH LOGIC ---
  void _switchCamera() {
    cameraController.switchCamera();
  }

  void _handleScan(BarcodeCapture capture) async {
    if (!_isScanning) return;

    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue == null) continue;

      setState(() { _isScanning = false; _message = "Processing..."; });

      try {
        String rawQrData = barcode.rawValue!;
        String staffId;

        // --- ROBUST PARSING LOGIC ---
        try {
          Map<String, dynamic> data = jsonDecode(rawQrData);
          if (data.containsKey('id')) {
            staffId = data['id'];
          } else if (data.containsKey('n')) {
            staffId = data['n'];
          } else {
            staffId = rawQrData;
          }
        } catch (e) {
          staffId = rawQrData;
        }

        staffId = staffId.trim().toUpperCase();

        var result = await DatabaseHelper().checkStaffStatus(staffId);

        if (result != null) {
          if (result['type'] == 'LOGGED') {
            _showResultScreen(
                color: Colors.blue,
                title: "ALREADY IN",
                subtitle: "Hall ${result['hall_no']}: ${result['staff_name']}"
            );
          } else {
            String hall = result['hall_no'];
            String name = result['staff_name'];
            await DatabaseHelper().markAttendance(staffId, name, hall);

            _showResultScreen(
                color: Colors.green,
                title: "HALL $hall",
                subtitle: "Welcome, $name"
            );
          }
        } else {
          _showSubstitutionDialog(staffId);
        }

      } catch (e) {
        _showResultScreen(color: Colors.red, title: "ERROR", subtitle: "Scan failed: $e");
      }
      break;
    }
  }

  void _showSubstitutionDialog(String substituteId) async {
    TextEditingController nameController = TextEditingController();
    List<Map<String, dynamic>> pendingList = await DatabaseHelper().getPendingHalls();

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            title: Text("Staff Not Allotted"),
            content: Container(
              width: double.maxFinite,
              height: 400,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("ID: $substituteId is not in schedule.", style: TextStyle(color: Colors.red)),
                  SizedBox(height: 10),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(labelText: "Enter Staff Name", border: OutlineInputBorder()),
                  ),
                  SizedBox(height: 10),
                  Text("Select replacement slot:", style: TextStyle(fontWeight: FontWeight.bold)),
                  Divider(),
                  Expanded(
                    child: pendingList.isEmpty
                        ? Center(child: Text("No pending slots."))
                        : ListView.builder(
                      itemCount: pendingList.length,
                      itemBuilder: (context, index) {
                        var item = pendingList[index];
                        return ListTile(
                          dense: true,
                          title: Text("Hall ${item['hall_no']}"),
                          subtitle: Text("Absent: ${item['staff_name']}"),
                          trailing: Icon(Icons.swap_horiz, color: Colors.orange),
                          onTap: () async {
                            if (nameController.text.isEmpty) return;
                            await DatabaseHelper().markSubstitution(
                                substituteId, nameController.text.trim(), item['hall_no']
                            );
                            Navigator.pop(context);
                            _showResultScreen(color: Colors.orange, title: "HALL ${item['hall_no']}", subtitle: "Replaced ${item['staff_name']}");
                          },
                        );
                      },
                    ),
                  )
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () { Navigator.pop(context); _resetScanner(); }, child: Text("Cancel"))
            ],
          );
        }
    );
  }

  void _showResultScreen({required Color color, required String title, required String subtitle}) {
    setState(() {
      _bgColor = color;
      _hallDisplay = title;
      _message = subtitle;
    });
  }

  void _resetScanner() {
    setState(() {
      _isScanning = true;
      _bgColor = Colors.white;
      _hallDisplay = null;
      _message = "Ready to Scan";
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hallDisplay != null) {
      return Scaffold(
        backgroundColor: _bgColor,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 80),
                SizedBox(height: 20),
                Text(_hallDisplay!, style: TextStyle(fontSize: 60, fontWeight: FontWeight.bold, color: Colors.white), textAlign: TextAlign.center),
                SizedBox(height: 20),
                Text(_message, style: TextStyle(fontSize: 24, color: Colors.white), textAlign: TextAlign.center),
                SizedBox(height: 60),
                SizedBox(width: double.infinity, height: 70, child: ElevatedButton.icon(onPressed: _resetScanner, icon: Icon(Icons.qr_code_scanner, color: _bgColor, size: 30), label: Text("RETURN TO SCANNER", style: TextStyle(color: _bgColor, fontSize: 20, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))))),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text("Scanner Mode"),
        actions: [
          // Optional Header Action
          IconButton(
            icon: Icon(Icons.cameraswitch),
            onPressed: _switchCamera,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Stack(
              children: [
                MobileScanner(
                  controller: cameraController,
                  onDetect: _handleScan,
                ),
                // FLOATING SWITCH CAMERA BUTTON
                Positioned(
                  bottom: 20,
                  right: 20,
                  child: FloatingActionButton(
                    backgroundColor: Colors.white.withOpacity(0.8),
                    onPressed: _switchCamera,
                    child: Icon(Icons.cameraswitch, color: Colors.black87),
                  ),
                ),
                // TORCH BUTTON (Bonus)
                Positioned(
                  bottom: 20,
                  left: 20,
                  child: FloatingActionButton(
                    backgroundColor: Colors.white.withOpacity(0.8),
                    onPressed: () => cameraController.toggleTorch(),
                    child: Icon(Icons.flash_on, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              color: Colors.black87,
              width: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Show QR Code", style: TextStyle(color: Colors.white, fontSize: 20)),
                  SizedBox(height: 10),
                  Text(_message, style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}