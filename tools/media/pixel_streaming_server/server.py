import argparse
import asyncio
import json
import logging
import os
import socket
import time
import uuid
import ctypes

import cv2
import mss
import numpy as np
from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from av import VideoFrame

# Try importing pygetwindow, handle failure gracefully
try:
    import pygetwindow as gw
    HAS_GW = True
    print("pygetwindow loaded successfully.")
except ImportError:
    HAS_GW = False
    print("pygetwindow not found. Install it with: pip install pygetwindow")

# Try importing win32 libs for background capture
try:
    import win32gui
    import win32ui
    import win32con
    HAS_WIN32 = True
    print("pywin32 loaded successfully (Background capture enabled).")
except ImportError:
    HAS_WIN32 = False
    print("pywin32 not found. Install it with: pip install pywin32")
    print("Falling back to screen capture (Foreground only).")

ROOT = os.path.dirname(__file__)
STREAM_KEY = os.environ.get("STREAM_KEY", "change-me")
pcs = set()

# UDP Socket for Godot
godot_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
GODOT_ADDR = ("127.0.0.1", 9000)

class ScreenCaptureTrack(VideoStreamTrack):
    def __init__(self):
        super().__init__()
        self.window_title = os.environ.get("GAME_WINDOW_TITLE", "Game")
        # Initial monitor setup to get dimensions (fallback)
        with mss.mss() as sct:
            if len(sct.monitors) > 1:
                self.monitor = sct.monitors[1]
            else:
                self.monitor = sct.monitors[0]
        self.last_check = 0
        self.found_window = False
        self.hwnd = None # Store window handle for win32 capture

    @staticmethod
    def _capture_mss(monitor):
        with mss.mss() as sct:
            return np.array(sct.grab(monitor))

    @staticmethod
    def _capture_win32(hwnd):
        try:
            # Validate handle first (window might have been closed)
            if not win32gui.IsWindow(hwnd):
                return None
            
            # Get window dimensions
            left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            w = right - left
            h = bottom - top
            
            if w <= 0 or h <= 0:
                return None

            # Create device context
            hwndDC = win32gui.GetWindowDC(hwnd)
            mfcDC = win32ui.CreateDCFromHandle(hwndDC)
            saveDC = mfcDC.CreateCompatibleDC()

            # Create bitmap
            saveBitMap = win32ui.CreateBitmap()
            saveBitMap.CreateCompatibleBitmap(mfcDC, w, h)
            saveDC.SelectObject(saveBitMap)

            # PrintWindow with PW_RENDERFULLCONTENT (0x00000002)
            # Use ctypes because win32gui.PrintWindow might be missing in some versions
            user32 = ctypes.windll.user32
            result = user32.PrintWindow(hwnd, saveDC.GetSafeHdc(), 2)
            
            if result != 1:
                # Cleanup on failure
                win32gui.DeleteObject(saveBitMap.GetHandle())
                saveDC.DeleteDC()
                mfcDC.DeleteDC()
                win32gui.ReleaseDC(hwnd, hwndDC)
                return None

            # Get bitmap bits
            bmpinfo = saveBitMap.GetInfo()
            bmpstr = saveBitMap.GetBitmapBits(True)

            # Convert to numpy array
            img = np.frombuffer(bmpstr, dtype='uint8')
            img.shape = (bmpinfo['bmHeight'], bmpinfo['bmWidth'], 4)

            # Cleanup
            win32gui.DeleteObject(saveBitMap.GetHandle())
            saveDC.DeleteDC()
            mfcDC.DeleteDC()
            win32gui.ReleaseDC(hwnd, hwndDC)

            return img
        except Exception as e:
            print(f"Win32 Capture Error: {e}")
            return None
        
    async def recv(self):
        pts, time_base = await self.next_timestamp()
        
        # Periodically check window position/existence (every 2 seconds)
        if HAS_GW and time.time() - self.last_check > 2.0:
            self.last_check = time.time()
            try:
                # Search for window
                windows = gw.getWindowsWithTitle(self.window_title)
                target_win = None
                
                if windows:
                    # Filter out browser windows or self-references
                    for w in windows:
                        title = w.title
                        if "Pixel Streaming" in title:
                            continue
                        if "Firefox" in title or "Chrome" in title or "Edge" in title:
                            continue
                        
                        # Avoid capturing the Godot Editor if the Game is running
                        # Game window usually has " (DEBUG)" or just the project name
                        # Editor has " - Godot Engine"
                        if "Godot Engine" in title and "DEBUG" not in title:
                             # Only skip if we haven't found a better one yet
                             # If we only find editor, we might have to take it, but let's try to find the game
                             pass
                        else:
                             target_win = w
                             break
                    
                    # If no optimal window found, fallback to first available (maybe just Editor is open)
                    if target_win is None and len(windows) > 0:
                         target_win = windows[0]
                
                if target_win:
                    if not self.found_window:
                        print(f"Found Godot window: '{target_win.title}' at {target_win.topleft}")
                        self.found_window = True
                    
                    # Store HWND for win32 capture (refresh each cycle in case window is closed/recreated)
                    if hasattr(target_win, '_hWnd'):
                         self.hwnd = target_win._hWnd
                    else:
                         self.hwnd = None
                        
                    if target_win.isMinimized:
                        target_win.restore()
                    
                    # mss monitor definition (still used if win32 capture fails)
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
                        print("Lost Godot window, reverting to full screen capture.")
                        self.found_window = False
                        self.hwnd = None
                        
            except Exception as e:
                pass

        # Capture Frame
        frame = None
        loop = asyncio.get_event_loop()

        # Try Background Capture first (Win32)
        if HAS_WIN32 and self.hwnd and self.found_window:
            try:
                frame = await loop.run_in_executor(None, self._capture_win32, self.hwnd)
                # If frame captured successfully, crop the title bar and borders if needed
                # PrintWindow captures the WHOLE window including borders.
                # We might want to crop it to match the 'client area'.
                # For simplicity, we return full window for now, or use the same offset logic
                if frame is not None:
                    # Crop: top 32, left 8, right 8, bottom 8 (approx)
                    # Ensure dimensions are valid
                    h, w, c = frame.shape
                    if h > 40 and w > 16:
                         frame = frame[32:h-8, 8:w-8]
            except Exception as e:
                print(f"Background capture failed: {e}")
                frame = None

        # Fallback to MSS (Screen Capture)
        if frame is None:
            try:
                frame = await loop.run_in_executor(None, self._capture_mss, self.monitor)
            except Exception as e:
                print(f"MSS Capture error: {e}")
                frame = np.zeros((480, 640, 4), dtype=np.uint8) # BGRA

        # Convert BGRA to BGR
        try:
            if frame is not None:
                frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
                
                new_frame = VideoFrame.from_ndarray(frame, format="bgr24")
                new_frame.pts = pts
                new_frame.time_base = time_base
                return new_frame
        except Exception as e:
             print(f"Frame conversion error: {e}")

        # Fallback black frame
        black = np.zeros((480, 640, 3), dtype=np.uint8)
        new_frame = VideoFrame.from_ndarray(black, format="bgr24")
        new_frame.pts = pts
        new_frame.time_base = time_base
        return new_frame

async def index(request):
    content = open(os.path.join(ROOT, "templates/index.html"), "r").read()
    return web.Response(content_type="text/html", text=content)

async def javascript(request):
    content = open(os.path.join(ROOT, "static/client.js"), "r").read()
    return web.Response(content_type="application/javascript", text=content)

async def offer(request):
    params = await request.json()
    
    if params.get("auth") != STREAM_KEY:
        return web.Response(status=401, text="Invalid Passphrase")

    offer = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    pcs.add(pc)

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        print("Connection state is %s" % pc.connectionState)
        if pc.connectionState == "failed":
            await pc.close()
            pcs.discard(pc)

    @pc.on("datachannel")
    def on_datachannel(channel):
        @channel.on("message")
        def on_message(message):
            try:
                godot_sock.sendto(message.encode('utf-8'), GODOT_ADDR)
            except Exception as e:
                print(f"Error sending to Godot: {e}")

    video = ScreenCaptureTrack()
    pc.addTrack(video)

    await pc.setRemoteDescription(offer)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)

    return web.Response(
        content_type="application/json",
        text=json.dumps(
            {"sdp": pc.localDescription.sdp, "type": pc.localDescription.type}
        ),
    )

async def on_shutdown(app):
    coros = [pc.close() for pc in pcs]
    await asyncio.gather(*coros)
    pcs.clear()

if __name__ == "__main__":
    app = web.Application()
    app.on_shutdown.append(on_shutdown)
    app.router.add_get("/", index)
    app.router.add_get("/client.js", javascript)
    app.router.add_post("/offer", offer)
    print("Server started at http://localhost:8080")
    web.run_app(app, access_log=None, port=8080)

