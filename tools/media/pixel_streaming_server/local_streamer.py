import asyncio
import json
import logging
import os
import socket
import time
import ctypes

import cv2
import mss
import numpy as np
import aiohttp
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from av import VideoFrame

# --- CAPTURE LOGIC (Same as before) ---
try:
    import pygetwindow as gw
    HAS_GW = True
except ImportError:
    HAS_GW = False

try:
    import win32gui
    import win32ui
    import win32con
    HAS_WIN32 = True
except ImportError:
    HAS_WIN32 = False

# Configuration
VDS_URL = os.environ.get("GAME_STREAM_PUBLISH_URL", "http://127.0.0.1:80/publish")
AUTH_KEY = os.environ.get("GAME_STREAM_KEY", "change-me")
GODOT_ADDR = ("127.0.0.1", 9000)

godot_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

class ScreenCaptureTrack(VideoStreamTrack):
    def __init__(self):
        super().__init__()
        self.window_title = os.environ.get("GAME_WINDOW_TITLE", "Game")
        with mss.mss() as sct:
            if len(sct.monitors) > 1:
                self.monitor = sct.monitors[1]
            else:
                self.monitor = sct.monitors[0]
        self.last_check = 0
        self.found_window = False
        self.hwnd = None 

    @staticmethod
    def _capture_mss(monitor):
        with mss.mss() as sct:
            return np.array(sct.grab(monitor))

    @staticmethod
    def _capture_win32(hwnd):
        try:
            left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            w = right - left
            h = bottom - top
            if w <= 0 or h <= 0: return None

            hwndDC = win32gui.GetWindowDC(hwnd)
            mfcDC = win32ui.CreateDCFromHandle(hwndDC)
            saveDC = mfcDC.CreateCompatibleDC()
            saveBitMap = win32ui.CreateBitmap()
            saveBitMap.CreateCompatibleBitmap(mfcDC, w, h)
            saveDC.SelectObject(saveBitMap)

            user32 = ctypes.windll.user32
            result = user32.PrintWindow(hwnd, saveDC.GetSafeHdc(), 2)
            
            if result != 1:
                win32gui.DeleteObject(saveBitMap.GetHandle())
                saveDC.DeleteDC()
                mfcDC.DeleteDC()
                win32gui.ReleaseDC(hwnd, hwndDC)
                return None

            bmpinfo = saveBitMap.GetInfo()
            bmpstr = saveBitMap.GetBitmapBits(True)
            img = np.frombuffer(bmpstr, dtype='uint8')
            img.shape = (bmpinfo['bmHeight'], bmpinfo['bmWidth'], 4)

            win32gui.DeleteObject(saveBitMap.GetHandle())
            saveDC.DeleteDC()
            mfcDC.DeleteDC()
            win32gui.ReleaseDC(hwnd, hwndDC)
            return img
        except Exception as e:
            return None
        
    async def recv(self):
        pts, time_base = await self.next_timestamp()
        
        # Window Check Logic
        if HAS_GW and time.time() - self.last_check > 2.0:
            self.last_check = time.time()
            try:
                windows = gw.getWindowsWithTitle(self.window_title)
                target_win = None
                if windows:
                    for w in windows:
                        # Filter out unwanted windows
                        if "Pixel Streaming" in w.title or "Firefox" in w.title or "Chrome" in w.title: continue
                        
                        # If multiple windows found (Editor + Game), try to distinguish
                        # Editor usually ends with "- Godot Engine"
                        # Game usually just has title or " (DEBUG)"
                        
                        # If we already found a window, check if this one is BETTER
                        if target_win:
                             # If current target is Editor, and new one is NOT Editor, switch
                             if "Godot Engine" in target_win.title and "Godot Engine" not in w.title:
                                 target_win = w
                        else:
                             target_win = w
                
                if target_win:
                    if not self.found_window:
                        print(f"Found Godot window: {target_win.title}")
                        self.found_window = True
                        if hasattr(target_win, '_hWnd'): self.hwnd = target_win._hWnd
                        
                    if target_win.isMinimized: target_win.restore()
                    
                    new_monitor = {
                        "top": int(target_win.top) + 32, 
                        "left": int(target_win.left) + 8,
                        "width": int(target_win.width) - 16,
                        "height": int(target_win.height) - 40
                    }
                    if new_monitor["width"] > 0 and new_monitor["height"] > 0:
                        if new_monitor["width"] % 2 != 0: new_monitor["width"] -= 1
                        if new_monitor["height"] % 2 != 0: new_monitor["height"] -= 1
                        self.monitor = new_monitor
                else:
                    if self.found_window:
                        self.found_window = False
                        self.hwnd = None
            except: pass

        # Capture
        frame = None
        loop = asyncio.get_event_loop()

        if HAS_WIN32 and self.hwnd and self.found_window:
            try:
                frame = await loop.run_in_executor(None, self._capture_win32, self.hwnd)
                if frame is not None:
                    h, w, c = frame.shape
                    if h > 40 and w > 16: frame = frame[32:h-8, 8:w-8]
            except: frame = None

        if frame is None:
            try:
                frame = await loop.run_in_executor(None, self._capture_mss, self.monitor)
            except: 
                frame = np.zeros((480, 640, 4), dtype=np.uint8)

        # Convert
        try:
            frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
            
            # LATENCY OPTIMIZATION: DISABLED SCALING (Send Raw)
            # User requested disabling processing to remove delay.
            # Note: This sends full resolution frames. If resolution is high, CPU usage goes up.
            h, w, _ = frame.shape
            if not hasattr(self, "_logged_size"):
                print(f"Actual Capture Resolution: {w}x{h}")
                print(f"Capture Method: {'Win32 (Background)' if HAS_WIN32 and self.hwnd and self.found_window else 'MSS (Screen)'}")
                self._logged_size = True

            # Ensure even dimensions (required by some encoders)
            if w % 2 != 0 or h % 2 != 0:
                 new_w = w if w % 2 == 0 else w - 1
                 new_h = h if h % 2 == 0 else h - 1
                 frame = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_NEAREST)

            new_frame = VideoFrame.from_ndarray(frame, format="bgr24")
            new_frame.pts = pts
            new_frame.time_base = time_base
            return new_frame
        except:
            return VideoFrame.from_ndarray(np.zeros((480, 640, 3), dtype=np.uint8), format="bgr24")

async def run_streamer():
    pc = RTCPeerConnection()
    
    # 1. Add Video Track
    video = ScreenCaptureTrack()
    pc.addTrack(video)
    
    # 2. Create Input Data Channel (We are the "Publisher" of this channel)
    # The VDS will forward messages from Client into this channel
    dc = pc.createDataChannel("input")
    
    @dc.on("open")
    def on_open():
        print("Input channel opened to VDS")
        
    @dc.on("message")
    def on_message(message):
        # Received input from VDS (originating from Viewer)
        try:
            godot_sock.sendto(message.encode('utf-8'), GODOT_ADDR)
        except Exception as e:
            print(f"Error forwarding input to Godot: {e}")

    # 3. Connect to VDS
    print(f"Connecting to VDS at {VDS_URL}...")
    
    try:
        # Create Offer
        offer = await pc.createOffer()
        await pc.setLocalDescription(offer)
        
        # Send Offer to VDS
        async with aiohttp.ClientSession() as session:
            async with session.post(
                VDS_URL, 
                json={"sdp": pc.localDescription.sdp, "type": pc.localDescription.type},
                headers={"X-Auth-Key": AUTH_KEY}
            ) as resp:
                if resp.status == 200:
                    answer_data = await resp.json()
                    answer = RTCSessionDescription(sdp=answer_data["sdp"], type=answer_data["type"])
                    await pc.setRemoteDescription(answer)
                    print("Connected to VDS! Stream is live.")
                else:
                    print(f"Failed to connect to VDS: {resp.status} {await resp.text()}")
                    await pc.close()
                    return
    except Exception as e:
        print(f"Connection error: {e}")
        await pc.close()
        return

    # Keep alive
    print("Press Ctrl+C to stop streaming")
    try:
        # Simple keep-alive loop
        while True:
            await asyncio.sleep(1)
            if pc.connectionState == "failed" or pc.connectionState == "closed":
                print("Connection lost. Exiting...")
                break
    except KeyboardInterrupt:
        pass
    finally:
        await pc.close()

if __name__ == "__main__":
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(run_streamer())

