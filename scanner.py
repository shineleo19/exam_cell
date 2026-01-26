import cv2
from pyzbar.pyzbar import decode
import time
import ctypes
import sys
import threading
import queue

# Windows User32 API setup
user32 = ctypes.windll.user32
SW_MINIMIZE = 6
SW_RESTORE = 9
WINDOW_NAME = "Secure Exam Scanner"

# Input Queue to handle commands from Flutter safely
input_queue = queue.Queue()

def read_stdin():
    """Reads commands from Flutter in a separate thread"""
    while True:
        try:
            line = sys.stdin.readline()
            if line:
                input_queue.put(line.strip())
        except:
            break

def start_scanner():
    # Start the listener thread
    threading.Thread(target=read_stdin, daemon=True).start()

    cap = cv2.VideoCapture(0)
    cap.set(3, 1280)
    cap.set(4, 720)

    print("CAMERA_READY", flush=True)

    is_paused = False

    while True:
        # 1. CHECK COMMANDS FROM FLUTTER
        if not input_queue.empty():
            cmd = input_queue.get()
            if cmd == "NEXT":
                # Restore Window
                hwnd = user32.FindWindowW(None, WINDOW_NAME)
                user32.ShowWindow(hwnd, SW_RESTORE)
                # Bring to front forcefully
                user32.SetForegroundWindow(hwnd)
                is_paused = False
            elif cmd == "STOP":
                break

        # 2. IF PAUSED (Result showing in Flutter), SKIP CAMERA
        if is_paused:
            time.sleep(0.1) # Save CPU
            continue

        # 3. NORMAL SCANNING LOOP
        success, frame = cap.read()
        if not success:
            continue

        decoded_objects = decode(frame)

        for obj in decoded_objects:
            qr_data = obj.data.decode('utf-8')

            if qr_data:
                # Send data to Flutter
                print(f"QR_DATA:{qr_data}", flush=True)

                # Draw Box for feedback
                pts = obj.polygon
                if len(pts) == 4:
                    import numpy as np
                    pts_array = np.array(pts, np.int32).reshape((-1, 1, 2))
                    cv2.polylines(frame, [pts_array], True, (0, 255, 0), 3)

                cv2.imshow(WINDOW_NAME, frame)
                cv2.waitKey(1)

                # MINIMIZE AND PAUSE
                hwnd = user32.FindWindowW(None, WINDOW_NAME)
                user32.ShowWindow(hwnd, SW_MINIMIZE)
                is_paused = True
                break

        cv2.imshow(WINDOW_NAME, frame)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    start_scanner()