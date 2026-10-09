import os
import sys
import time
import base64
import asyncio
import websockets
import cv2
import numpy as np
import av
import json
import threading
from pydub import AudioSegment
from pydub.utils import make_chunks
from io import BytesIO
import subprocess
import platform
import argparse
import signal
import atexit
import urllib.request
import ctypes
from collections import deque

# --- Windows high-resolution timer (Solution B) ---
# Windows' default scheduler/timer granularity is ~15.6ms, which wrecks the
# sleep-based A/V pacing in these streamers and is a major cause of audio drift
# ("ses kaymasi"). Requesting 1ms resolution via winmm brings pacing in line with
# macOS (~1ms). These helpers are no-ops on non-Windows platforms, so the macOS
# behaviour is left completely unchanged.
_WINMM_TIMER_PERIOD_MS = 1

def _enable_high_res_timer():
    if platform.system().lower() != "windows":
        return
    try:
        ctypes.windll.winmm.timeBeginPeriod(_WINMM_TIMER_PERIOD_MS)
        atexit.register(_disable_high_res_timer)
        print(f"Enabled {_WINMM_TIMER_PERIOD_MS}ms timer resolution (Windows).")
    except Exception as e:
        print(f"Could not set high-resolution timer: {e}")

def _disable_high_res_timer():
    if platform.system().lower() != "windows":
        return
    try:
        ctypes.windll.winmm.timeEndPeriod(_WINMM_TIMER_PERIOD_MS)
    except Exception:
        pass

class DirectMediaStreamer:
    def __init__(self, video_path=None, capture_width=320, capture_height=240, 
                 websocket_port=3245, frame_rate=30, audio_chunk_ms=40, letterbox=False):
        """Initialize direct media streamer for video and audio."""
        self.video_path = video_path
        
        # Streaming settings
        self.capture_width = capture_width
        self.capture_height = capture_height
        self.websocket_port = websocket_port
        self.frame_rate = frame_rate
        self.audio_chunk_ms = audio_chunk_ms
        self.letterbox = letterbox
        self.running = False
        self.connected_clients = set()
        
        # Media resources
        self.media_thread = None
        self.video_thread = None
        self.video_capture = None
        self.audio_segment = None
        self.audio_chunks = []

        # Platform-specific video path (Solution A).
        # On Windows we offload decode + scale + JPEG encode to an FFmpeg subprocess
        # (GPU decode via d3d11va) instead of doing it in-process with OpenCV. This
        # keeps the heavy work out of Python's GIL so the audio loop stops starving.
        # macOS keeps using the original cv2.VideoCapture path.
        self.os_type = platform.system().lower()
        self.use_ffmpeg_pipe = (self.os_type == "windows")
        self.video_process = None
        self.video_fps = 30.0
        self._jpeg_buffer = bytearray()
        
        # Use an asyncio queue for thread-safe broadcasting
        self.broadcast_queue = asyncio.Queue()
        
        # Shared state between threads
        self.current_video_frame = None  # Latest encoded video frame (base64)
        self.video_frame_lock = threading.Lock()  # Protect access to current_video_frame
        
    async def websocket_handler(self, websocket):
        """Handle WebSocket connections from Godot."""
        print(f"Client connected: {websocket.remote_address}")
        self.connected_clients.add(websocket)
        try:
            # Keep connection open, handle potential commands if needed later
            await websocket.wait_closed()
        finally:
            self.connected_clients.remove(websocket)
            print(f"Client disconnected: {websocket.remote_address}")
    
    async def broadcast_loop(self):
        """Coroutine that takes messages from the queue and broadcasts them."""
        while True:
            try:
                message = await self.broadcast_queue.get()
                if message is None: # Signal to stop
                    break

                if not self.connected_clients:
                    self.broadcast_queue.task_done()
                    continue # Skip if no clients

                disconnected = set()
                message_json = json.dumps(message)

                # Use asyncio.gather for concurrent sends
                tasks = [ws.send(message_json) for ws in self.connected_clients]
                results = await asyncio.gather(*tasks, return_exceptions=True)

                # Check for errors (disconnected clients)
                client_list = list(self.connected_clients)
                for i, result in enumerate(results):
                    if isinstance(result, websockets.exceptions.ConnectionClosed):
                        disconnected.add(client_list[i])
                        # print(f"Client {client_list[i].remote_address} disconnected during send.")

                self.connected_clients -= disconnected
                self.broadcast_queue.task_done()

            except asyncio.CancelledError:
                print("Broadcast loop cancelled.")
                break
            except Exception as e:
                print(f"Error in broadcast loop: {e}")
                # Clear queue on error? Or just continue?
                self.broadcast_queue.task_done() # Ensure task is marked done

    async def start_websocket_server(self):
        """Start the WebSocket server and the broadcast loop."""
        server = await websockets.serve(
            self.websocket_handler,
            "localhost",
            self.websocket_port
        )
        print(f"WebSocket server started on ws://localhost:{self.websocket_port}")

        # Start the broadcast loop as a separate task
        broadcast_task = asyncio.create_task(self.broadcast_loop())

        try:
            await server.wait_closed()
        finally:
            # Signal broadcast loop to stop and wait for it
            await self.broadcast_queue.put(None)
            await broadcast_task
            server.close()
            await server.wait_closed()
            print("WebSocket server stopped.")

    def _prepare_media(self):
        """Extracts audio and prepares video capture."""
        print("Preparing media...")
        # 1. Extract Audio to WAV using FFmpeg
        temp_audio_file = f"temp_audio_{int(time.time())}.wav"
        try:
            container = av.open(self.video_path)
            audio_stream = next((s for s in container.streams if s.type == 'audio'), None)
            if not audio_stream:
                print("No audio stream found.")
                return False
            sample_rate = audio_stream.sample_rate
            channels = audio_stream.channels
            container.close() # Close av container

            # Force 48000 Hz sample rate to match Godot expectations
            target_sample_rate = 48000
            ffmpeg_cmd = [
                "ffmpeg", "-y",
                "-i", self.video_path,
                "-vn", "-acodec", "pcm_s16le",
                "-ar", str(target_sample_rate), "-ac", "2",  # Force stereo 48kHz
                temp_audio_file
            ]
            print(f"Extracting audio at {target_sample_rate}Hz (original: {sample_rate}Hz): {' '.join(ffmpeg_cmd)}")
            subprocess.run(ffmpeg_cmd, check=True, capture_output=True)

            if not os.path.exists(temp_audio_file):
                print("Failed to create temp audio file.")
                return False

            # 2. Load Audio with pydub and Chunk
            print(f"Loading audio from {temp_audio_file}...")
            self.audio_segment = AudioSegment.from_file(temp_audio_file, format="wav")
            print(f"Audio loaded: {len(self.audio_segment)/1000:.2f}s")
            self.audio_chunks = make_chunks(self.audio_segment, self.audio_chunk_ms)
            print(f"Created {len(self.audio_chunks)} audio chunks of {self.audio_chunk_ms}ms")

        except Exception as e:
            print(f"Error preparing audio: {e}")
            return False
        finally:
            # Clean up temp file
            if os.path.exists(temp_audio_file):
                try:
                    os.remove(temp_audio_file)
                    print(f"Removed temp audio file: {temp_audio_file}")
                except Exception as e:
                    print(f"Failed to remove temp file: {e}")

        # 3. Prepare Video Capture
        print("Opening video capture...")
        if self.use_ffmpeg_pipe:
            # Windows: FFmpeg does decode + scale + MJPEG encode on a pipe (Solution A).
            if not self._start_video_ffmpeg():
                print("Failed to start FFmpeg video pipe.")
                return False
        else:
            self.video_capture = cv2.VideoCapture(self.video_path, cv2.CAP_FFMPEG)
            self.video_capture.set(cv2.CAP_PROP_HW_ACCELERATION, cv2.VIDEO_ACCELERATION_ANY)
            if not self.video_capture.isOpened():
                print(f"Could not open video file: {self.video_path}")
                return False
            video_fps = self.video_capture.get(cv2.CAP_PROP_FPS)
            frame_count = self.video_capture.get(cv2.CAP_PROP_FRAME_COUNT)
            self.video_fps = video_fps if video_fps > 0 else 30.0
            print(f"Video capture opened: {video_fps:.2f} FPS, {frame_count:.0f} frames")

        return True

    # --- Windows FFmpeg video pipe helpers (Solution A) ---

    def _probe_video_fps(self):
        """Get the source video FPS via PyAV (fallback 30)."""
        try:
            container = av.open(self.video_path)
            vstream = next((s for s in container.streams if s.type == 'video'), None)
            fps = float(vstream.average_rate) if (vstream and vstream.average_rate) else 30.0
            container.close()
            return fps if fps > 0 else 30.0
        except Exception as e:
            print(f"Could not probe video FPS, defaulting to 30: {e}")
            return 30.0

    def _build_video_ffmpeg_cmd(self, use_hw):
        """Build the FFmpeg command that emits scaled MJPEG frames to stdout."""
        target_w, target_h = self.capture_width, self.capture_height
        if self.letterbox:
            vf = (f"scale={target_w}:{target_h}:force_original_aspect_ratio=decrease,"
                  f"pad={target_w}:{target_h}:(ow-iw)/2:(oh-ih)/2")
        else:
            vf = f"scale={target_w}:{target_h}"
        cmd = ["ffmpeg"]
        if use_hw:
            cmd += ["-hwaccel", "d3d11va"]  # GPU decode on AMD/any D3D11 device
        cmd += [
            "-i", self.video_path,
            "-an",                       # no audio (handled separately by pydub)
            "-vf", vf,
            "-c:v", "mjpeg",
            "-q:v", "3",                 # high quality (lower = better)
            "-f", "image2pipe",
            "pipe:1",
        ]
        return cmd

    @staticmethod
    def _drain_pipe(pipe, tail):
        """Continuously drain a subprocess pipe into a bounded buffer.

        FFmpeg writes a lot to stderr; if it is never read the OS pipe fills and
        FFmpeg blocks. This keeps it flowing and retains the last lines for errors.
        """
        try:
            for line in iter(pipe.readline, b""):
                tail.append(line.decode("utf-8", errors="ignore"))
        except Exception:
            pass

    def _start_video_ffmpeg(self):
        """Spawn FFmpeg to produce scaled MJPEG frames on a pipe.

        Tries GPU decode (d3d11va) first; if FFmpeg exits immediately (e.g. the
        hardware decoder rejects the codec) it falls back to software decode.
        """
        self.video_fps = self._probe_video_fps()
        creationflags = subprocess.CREATE_NO_WINDOW if hasattr(subprocess, "CREATE_NO_WINDOW") else 0

        for use_hw in (True, False):
            cmd = self._build_video_ffmpeg_cmd(use_hw)
            mode = "GPU (d3d11va)" if use_hw else "software"
            print(f"Starting FFmpeg video pipe [{mode}] at {self.video_fps:.2f} FPS")
            tail = deque(maxlen=50)
            self.video_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=10 * 1024 * 1024,
                creationflags=creationflags,
            )
            threading.Thread(
                target=self._drain_pipe,
                args=(self.video_process.stderr, tail),
                daemon=True,
            ).start()
            # If the args/decoder are bad, FFmpeg dies within ~1s; otherwise it stays
            # alive (and blocks on a full stdout pipe until we start reading frames).
            time.sleep(1.0)
            if self.video_process.poll() is None:
                return True
            print(f"FFmpeg [{mode}] exited early (code {self.video_process.returncode}).")
            if use_hw:
                print("Falling back to software decode...")
            else:
                print("FFmpeg stderr (tail):\n" + "".join(tail))
        return False

    def _read_next_jpeg(self):
        """Return the next complete JPEG frame from the FFmpeg pipe, or None at EOF."""
        SOI = b"\xff\xd8"
        EOI = b"\xff\xd9"
        buf = self._jpeg_buffer
        while True:
            start = buf.find(SOI)
            if start != -1:
                end = buf.find(EOI, start + 2)
                if end != -1:
                    frame = bytes(buf[start:end + 2])
                    del buf[:end + 2]
                    return frame
            chunk = self.video_process.stdout.read(65536)
            if not chunk:
                return None
            buf += chunk

    def _video_thread_ffmpeg(self, start_time):
        """Windows video loop: read pre-encoded JPEGs from FFmpeg, pace, publish.

        No decode/resize/encode happens in Python here - FFmpeg already produced the
        JPEG, so this thread only paces and base64-encodes, leaving CPU for audio.
        """
        video_fps = self.video_fps if self.video_fps > 0 else 30.0
        frame_interval = 1.0 / video_fps
        print(f"Video thread (FFmpeg pipe) running at {video_fps:.2f} FPS "
              f"(frame interval: {frame_interval*1000:.1f}ms)")
        frame_index = 0
        while self.running:
            expected_time = start_time + (frame_index * frame_interval)
            sleep_time = expected_time - time.time()
            if sleep_time > 0:
                time.sleep(sleep_time)
            try:
                jpeg = self._read_next_jpeg()
                if jpeg is None:
                    print("Video processing: End of FFmpeg stream")
                    break
                video_b64 = base64.b64encode(jpeg).decode("utf-8")
                with self.video_frame_lock:
                    self.current_video_frame = video_b64
                frame_index += 1
            except Exception as e:
                print(f"Error in FFmpeg video processing: {e}")
                time.sleep(0.1)
                continue
        print("Video processing thread finished.")

    def cleanup(self):
        """Stop streaming and tear down media resources (safe to call repeatedly)."""
        self.running = False
        if self.video_process:
            try:
                self.video_process.terminate()
            except Exception:
                pass
        if self.video_capture:
            try:
                self.video_capture.release()
            except Exception:
                pass

    def _letterbox_frame(self, frame, target_w, target_h):
        """Resize frame with letterboxing to preserve aspect ratio."""
        h, w = frame.shape[:2]
        src_aspect = w / h
        dst_aspect = target_w / target_h
        
        if abs(src_aspect - dst_aspect) < 0.01:  # Aspect ratios are close enough
            return cv2.resize(frame, (target_w, target_h), interpolation=cv2.INTER_LINEAR)
        
        # Calculate dimensions preserving aspect ratio
        if src_aspect > dst_aspect:
            # Source is wider - add top/bottom bars (letterbox)
            new_w = target_w
            new_h = int(target_w / src_aspect)
        else:
            # Source is taller - add left/right bars (pillarbox)
            new_h = target_h
            new_w = int(target_h * src_aspect)
        
        # Resize frame to fit within target dimensions
        resized = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
        
        # Create black canvas and place resized frame in center
        canvas = np.zeros((target_h, target_w, 3), dtype=np.uint8)
        y_offset = (target_h - new_h) // 2
        x_offset = (target_w - new_w) // 2
        canvas[y_offset:y_offset+new_h, x_offset:x_offset+new_w] = resized
        
        return canvas

    def video_processing_thread(self, start_time):
        """Separate thread for video frame processing - synced to actual video timing"""
        print("Video processing thread started...")
        if self.use_ffmpeg_pipe:
            # Windows path (Solution A): FFmpeg already produced the JPEGs.
            self._video_thread_ffmpeg(start_time)
            return
        target_w, target_h = self.capture_width, self.capture_height
        quality = 65 if target_w > 800 else 75 if target_w > 640 else 85
        encode_params = [cv2.IMWRITE_JPEG_QUALITY, quality, cv2.IMWRITE_JPEG_OPTIMIZE, 1]
        
        # Get actual video FPS from the video file
        video_fps = self.video_capture.get(cv2.CAP_PROP_FPS)
        if video_fps <= 0:
            video_fps = 30  # Fallback
        frame_interval = 1.0 / video_fps
        print(f"Video thread running at {video_fps:.2f} FPS (frame interval: {frame_interval*1000:.1f}ms)")
        
        frame_index = 0
        
        while self.running:
            # Calculate when this frame should be displayed
            expected_time = start_time + (frame_index * frame_interval)
            current_time = time.time()
            
            # Sleep until it's time for this frame
            sleep_time = expected_time - current_time
            if sleep_time > 0:
                time.sleep(sleep_time)
            
            try:
                ret, frame = self.video_capture.read()
                if not ret:
                    print("Video processing: End of video reached")
                    break
                
                # Resize frame efficiently (with or without letterboxing)
                if self.letterbox:
                    canvas = self._letterbox_frame(frame, target_w, target_h)
                else:
                    canvas = cv2.resize(frame, (target_w, target_h), interpolation=cv2.INTER_LINEAR)
                
                # Encode to JPEG
                _, buffer = cv2.imencode('.jpg', canvas, encode_params)
                video_b64 = base64.b64encode(buffer).decode('utf-8')
                
                # Update shared frame (thread-safe)
                with self.video_frame_lock:
                    self.current_video_frame = video_b64
                
                frame_index += 1
                
            except Exception as e:
                print(f"Error in video processing: {e}")
                time.sleep(0.1)
                continue
        
        print("Video processing thread finished.")
    
    def process_and_stream_media(self, loop):
        """Main loop to process and queue media chunks for broadcasting."""
        if not self._prepare_media():
            print("Media preparation failed. Stopping.")
            # Signal broadcast loop to stop if it was started
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)
            return

        self.running = True
        start_time = time.time()
        chunk_duration_sec = self.audio_chunk_ms / 1000.0
        total_chunks = len(self.audio_chunks)

        print("Starting media streaming loop...")
        
        # Start video processing in a separate thread with same start time
        self.video_thread = threading.Thread(target=self.video_processing_thread, args=(start_time,), daemon=True)
        self.video_thread.start()
        
        try:
            for i, audio_chunk in enumerate(self.audio_chunks):
                if not self.running:
                    print("Streaming loop interrupted.")
                    break

                current_chunk_start_ms = i * self.audio_chunk_ms
                
                # --- Get Latest Video Frame (non-blocking) ---
                video_b64 = ""
                with self.video_frame_lock:
                    if self.current_video_frame:
                        video_b64 = self.current_video_frame

                # --- Timing Control ---
                # Sleep to maintain precise audio timing
                expected_time = start_time + i * chunk_duration_sec
                current_time = time.time()
                sleep_time = expected_time - current_time

                if sleep_time > 0:
                    time.sleep(sleep_time)

                # --- Audio Chunk Handling ---
                # Export audio chunk to WAV bytes efficiently
                wav_bytes = audio_chunk.raw_data
                
                # Create minimal WAV header (44 bytes)
                sample_rate = 48000
                num_channels = 2
                bits_per_sample = 16
                byte_rate = sample_rate * num_channels * bits_per_sample // 8
                block_align = num_channels * bits_per_sample // 8
                data_size = len(wav_bytes)
                
                wav_header = (
                    b'RIFF' + 
                    (data_size + 36).to_bytes(4, 'little') +
                    b'WAVE' +
                    b'fmt ' + 
                    (16).to_bytes(4, 'little') +  # fmt chunk size
                    (1).to_bytes(2, 'little') +   # audio format (PCM)
                    num_channels.to_bytes(2, 'little') +
                    sample_rate.to_bytes(4, 'little') +
                    byte_rate.to_bytes(4, 'little') +
                    block_align.to_bytes(2, 'little') +
                    bits_per_sample.to_bytes(2, 'little') +
                    b'data' +
                    data_size.to_bytes(4, 'little')
                )
                
                full_wav = wav_header + wav_bytes
                audio_b64 = base64.b64encode(full_wav).decode('utf-8')

                # --- Create Combined Message ---
                message = {
                    "type": "media_chunk",
                    "audio_data": audio_b64,
                    "video_data": video_b64,
                    "timestamp_ms": current_chunk_start_ms, # Include timestamp
                    "chunk_info": { # Optional info
                        "index": i,
                        "total": total_chunks
                    }
                    # Add spatial info here if needed, e.g., based on time 'i'
                }

                # --- Queue Message for Broadcasting ---
                # Put the message onto the asyncio queue for the broadcast loop
                # This is thread-safe
                # Don't wait for put confirmation - just queue it and move on
                try:
                    asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(message), loop)
                except Exception as e:
                    print(f"Error putting message on queue: {e}")
                    break # Stop if queueing fails badly

                if i % 50 == 0: # Log progress occasionally
                     print(f"Processed chunk {i}/{total_chunks}")


        except Exception as e:
            print(f"Error in media processing loop: {e}")
            import traceback
            traceback.print_exc()
        finally:
            print("Media streaming loop finished.")
            self.running = False
            if self.video_capture:
                self.video_capture.release()
                print("Video capture released.")
            if self.video_process:
                try:
                    self.video_process.terminate()
                    print("FFmpeg video process terminated.")
                except Exception:
                    pass
            # Signal broadcast loop to stop
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)

    def stream_media(self, video_path=None):
        """Start streaming media to connected clients."""
        if video_path:
            self.video_path = video_path

        if not self.video_path or not os.path.isfile(self.video_path):
            raise FileNotFoundError(f"Video file not found or not specified: {self.video_path}")

        # Run the WebSocket server and processing loop in a new thread
        # The server itself needs an event loop
        def run_server_and_processor():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            # Start the WebSocket server (which includes the broadcast loop)
            server_task = loop.create_task(self.start_websocket_server())

            # Run the blocking media processing in the loop's executor
            # Or just run it directly if it handles its own async interactions correctly
            # loop.run_in_executor(None, self.process_and_stream_media, loop)
            # Running directly might be okay since process_and_stream_media uses run_coroutine_threadsafe
            processing_thread = threading.Thread(target=self.process_and_stream_media, args=(loop,))
            processing_thread.start()


            try:
                loop.run_forever()
            finally:
                print("Event loop stopping...")
                # Ensure processing thread is stopped if loop exits unexpectedly
                self.running = False
                processing_thread.join(timeout=2.0)

                # Cleanly shut down server task
                if not server_task.done():
                    server_task.cancel()
                    try:
                        loop.run_until_complete(server_task)
                    except asyncio.CancelledError:
                        pass # Expected
                loop.close()
                print("Event loop closed.")

        self.media_thread = threading.Thread(target=run_server_and_processor)
        self.media_thread.daemon = True # Allow exit even if this thread is running
        self.media_thread.start()

        return self.media_thread

class DesktopStreamer:
    def __init__(self, capture_width=1280, capture_height=720, 
                websocket_port=3245, frame_rate=30, audio_chunk_ms=40, letterbox=False):
        """Initialize desktop streamer for screen capture and audio."""
        # Streaming settings
        self.capture_width = capture_width
        self.capture_height = capture_height
        self.websocket_port = websocket_port
        self.frame_rate = frame_rate
        self.audio_chunk_ms = audio_chunk_ms
        self.letterbox = letterbox
        self.running = False
        self.connected_clients = set()
        
        # Media resources
        self.media_thread = None
        self.screen_capture = None
        
        # Detect operating system
        self.os_type = platform.system().lower()
        print(f"Detected OS: {self.os_type}")
        
        # Use an asyncio queue for thread-safe broadcasting
        self.broadcast_queue = asyncio.Queue()
        
    async def websocket_handler(self, websocket):
        """Handle WebSocket connections from Godot."""
        print(f"Client connected: {websocket.remote_address}")
        self.connected_clients.add(websocket)
        try:
            # Keep connection open, handle potential commands if needed later
            await websocket.wait_closed()
        finally:
            self.connected_clients.remove(websocket)
            print(f"Client disconnected: {websocket.remote_address}")
    
    async def broadcast_loop(self):
        """Coroutine that takes messages from the queue and broadcasts them."""
        while True:
            try:
                message = await self.broadcast_queue.get()
                if message is None: # Signal to stop
                    break

                if not self.connected_clients:
                    self.broadcast_queue.task_done()
                    continue # Skip if no clients

                disconnected = set()
                message_json = json.dumps(message)

                # Use asyncio.gather for concurrent sends
                tasks = [ws.send(message_json) for ws in self.connected_clients]
                results = await asyncio.gather(*tasks, return_exceptions=True)

                # Check for errors (disconnected clients)
                client_list = list(self.connected_clients)
                for i, result in enumerate(results):
                    if isinstance(result, websockets.exceptions.ConnectionClosed):
                        disconnected.add(client_list[i])

                self.connected_clients -= disconnected
                self.broadcast_queue.task_done()

            except asyncio.CancelledError:
                print("Broadcast loop cancelled.")
                break
            except Exception as e:
                print(f"Error in broadcast loop: {e}")
                self.broadcast_queue.task_done()

    async def start_websocket_server(self):
        """Start the WebSocket server and the broadcast loop."""
        server = await websockets.serve(
            self.websocket_handler,
            "0.0.0.0",  # Listen on all interfaces to allow connections from other machines
            self.websocket_port
        )
        print(f"WebSocket server started on ws://0.0.0.0:{self.websocket_port}")

        # Start the broadcast loop as a separate task
        broadcast_task = asyncio.create_task(self.broadcast_loop())

        try:
            await server.wait_closed()
        finally:
            # Signal broadcast loop to stop and wait for it
            await self.broadcast_queue.put(None)
            await broadcast_task
            server.close()
            await server.wait_closed()
            print("WebSocket server stopped.")

    def _setup_screen_capture(self):
        """Set up screen capture for different operating systems."""
        try:
            if self.os_type == "darwin":  # macOS
                return self._setup_macos_capture()
            elif self.os_type == "windows":  # Windows
                return self._setup_windows_capture()
            else:
                print(f"Unsupported operating system: {self.os_type}")
                return False
        except Exception as e:
            print(f"Error setting up capture: {e}")
            return False

    def _letterbox_frame(self, frame, target_w, target_h):
        """Resize frame with letterboxing to preserve aspect ratio."""
        h, w = frame.shape[:2]
        src_aspect = w / h
        dst_aspect = target_w / target_h
        
        if abs(src_aspect - dst_aspect) < 0.01:  # Aspect ratios are close enough
            return cv2.resize(frame, (target_w, target_h), interpolation=cv2.INTER_LINEAR)
        
        # Calculate dimensions preserving aspect ratio
        if src_aspect > dst_aspect:
            # Source is wider - add top/bottom bars (letterbox)
            new_w = target_w
            new_h = int(target_w / src_aspect)
        else:
            # Source is taller - add left/right bars (pillarbox)
            new_h = target_h
            new_w = int(target_h * src_aspect)
        
        # Resize frame to fit within target dimensions
        resized = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
        
        # Create black canvas and place resized frame in center
        canvas = np.zeros((target_h, target_w, 3), dtype=np.uint8)
        y_offset = (target_h - new_h) // 2
        x_offset = (target_w - new_w) // 2
        canvas[y_offset:y_offset+new_h, x_offset:x_offset+new_w] = resized
        
        return canvas

    def _setup_macos_capture(self):
        """Set up screen capture for macOS using AVFoundation."""
        # Set up the command to capture screen using ffmpeg
        if self.letterbox:
            # Use scale and pad filters to preserve aspect ratio
            vf_filter = f"scale={self.capture_width}:{self.capture_height}:force_original_aspect_ratio=decrease,pad={self.capture_width}:{self.capture_height}:(ow-iw)/2:(oh-ih)/2"
            self.screen_capture_cmd = [
                "ffmpeg",
                "-f", "avfoundation",  # macOS capture framework
                "-i", "1:0",  # "1" is usually the screen, "0" is usually the default audio device
                "-vf", vf_filter,  # Scale with aspect ratio preservation and pad
                "-pix_fmt", "bgr24",  # OpenCV compatible format
                "-r", str(self.frame_rate),  # Frame rate
                "-f", "rawvideo",  # Raw video output
                "pipe:1"  # Output to stdout
            ]
        else:
            self.screen_capture_cmd = [
                "ffmpeg",
                "-f", "avfoundation",  # macOS capture framework
                "-i", "1:0",  # "1" is usually the screen, "0" is usually the default audio device
                "-pix_fmt", "bgr24",  # OpenCV compatible format
                "-s", f"{self.capture_width}x{self.capture_height}",  # Resolution
                "-r", str(self.frame_rate),  # Frame rate
                "-f", "rawvideo",  # Raw video output
                "pipe:1"  # Output to stdout
            ]
        
        # Open the process
        self.screen_process = subprocess.Popen(
            self.screen_capture_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
        # Set up the command to capture audio using ffmpeg
        self.audio_capture_cmd = [
            "ffmpeg",
            "-f", "avfoundation",
            "-i", "none:0",  # "none" for video, "0" for default audio device
            "-ar", "48000",  # Audio sample rate
            "-ac", "2",      # Audio channels (stereo)
            "-f", "wav",     # WAV format
            "pipe:1"         # Output to stdout
        ]
        
        # Open the process
        self.audio_process = subprocess.Popen(
            self.audio_capture_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
        print("macOS screen and audio capture started.")
        return True

    def _setup_windows_capture(self):
        """Set up screen capture for Windows using DirectShow/GDI."""
        # Set up the command to capture screen using ffmpeg with Windows-specific options
        if self.letterbox:
            # Use scale and pad filters to preserve aspect ratio
            vf_filter = f"scale={self.capture_width}:{self.capture_height}:force_original_aspect_ratio=decrease,pad={self.capture_width}:{self.capture_height}:(ow-iw)/2:(oh-ih)/2"
            self.screen_capture_cmd = [
                "ffmpeg",
                "-f", "gdigrab",  # Windows GDI screen capture
                "-i", "desktop",  # Capture the desktop
                "-vf", vf_filter,  # Scale with aspect ratio preservation and pad
                "-pix_fmt", "bgr24",  # OpenCV compatible format
                "-r", str(self.frame_rate),  # Frame rate
                "-f", "rawvideo",  # Raw video output
                "pipe:1"  # Output to stdout
            ]
        else:
            self.screen_capture_cmd = [
                "ffmpeg",
                "-f", "gdigrab",  # Windows GDI screen capture
                "-i", "desktop",  # Capture the desktop
                "-pix_fmt", "bgr24",  # OpenCV compatible format
                "-s", f"{self.capture_width}x{self.capture_height}",  # Resolution
                "-r", str(self.frame_rate),  # Frame rate
                "-f", "rawvideo",  # Raw video output
                "pipe:1"  # Output to stdout
            ]
        
        # Open the process
        self.screen_process = subprocess.Popen(
            self.screen_capture_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
        )
        
        # Set up the command to capture audio using ffmpeg with DirectShow
        self.audio_capture_cmd = [
            "ffmpeg",
            "-f", "dshow",  # DirectShow for Windows
            "-i", "audio=CABLE Input (VB-Audio Virtual Cable)",  # VB-Audio Virtual Cable
            "-ar", "48000",  # Audio sample rate
            "-ac", "2",      # Audio channels (stereo)
            "-f", "wav",     # WAV format
            "pipe:1"         # Output to stdout
        ]
        
        # Try to open audio capture process
        try:
            self.audio_process = subprocess.Popen(
                self.audio_capture_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
            )
            print("Windows screen and audio capture started with VB-Audio Virtual Cable.")
        except Exception as e:
            print(f"VB-Audio Virtual Cable capture failed: {e}")
            print("Trying alternative audio devices...")
            # Try alternative audio device names
            alternative_audio_devices = [
                "audio=Stereo Mix",
                "audio=Microphone",
                "audio=Line In", 
                "audio=What U Hear",
                "audio=Wave Out Mix"
            ]
            
            self.audio_process = None
            for device in alternative_audio_devices:
                try:
                    alt_cmd = self.audio_capture_cmd.copy()
                    alt_cmd[3] = device  # Replace the -i parameter
                    self.audio_process = subprocess.Popen(
                        alt_cmd,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
                    )
                    print(f"Audio capture started with device: {device}")
                    break
                except Exception:
                    continue
            
            if self.audio_process is None:
                print("Warning: No audio capture available. Video-only mode.")
        
        return True

    def capture_and_stream_desktop(self, loop):
        """Capture and stream desktop screen and audio."""
        if not self._setup_screen_capture():
            print("Screen capture setup failed. Stopping.")
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)
            return

        self.running = True
        frame_size = self.capture_width * self.capture_height * 3  # BGR24 format
        frame_time = 1.0 / self.frame_rate
        
        print("Starting desktop streaming loop...")
        try:
            frame_count = 0
            start_time = time.time()
            
            while self.running:
                # Read raw video frame
                raw_frame = self.screen_process.stdout.read(frame_size)
                if len(raw_frame) != frame_size:
                    print("End of screen capture stream.")
                    break

                # Convert raw frame to numpy array and reshape
                frame = np.frombuffer(raw_frame, dtype=np.uint8).reshape(self.capture_height, self.capture_width, 3)
                
                # Read audio chunk (if audio process is available)
                audio_b64 = ""
                if hasattr(self, 'audio_process') and self.audio_process is not None:
                    try:
                        audio_bytes = BytesIO()
                        audio_chunk_size = int(48000 * 2 * 2 * frame_time)  # Sample rate * channels * bytes_per_sample * time
                        audio_data = self.audio_process.stdout.read(audio_chunk_size)
                        if audio_data:
                            audio_bytes.write(audio_data)
                            audio_bytes.seek(0)
                            audio_b64 = base64.b64encode(audio_bytes.getvalue()).decode('utf-8')
                    except Exception as e:
                        if frame_count % 100 == 0:  # Log occasionally to avoid spam
                            print(f"Audio read error: {e}")
                
                # Encode video frame
                _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                video_b64 = base64.b64encode(buffer).decode('utf-8')
                
                # Create message
                message = {
                    "type": "media_chunk",
                    "audio_data": audio_b64,
                    "video_data": video_b64,
                    "timestamp_ms": int((time.time() - start_time) * 1000),
                    "chunk_info": {
                        "index": frame_count,
                        "total": -1  # Live stream, unknown total
                    }
                }
                
                # Queue for broadcasting
                future = asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(message), loop)
                try:
                    future.result(timeout=frame_time)  # Wait briefly for put confirmation
                except TimeoutError:
                    print("Warning: Broadcast queue put timed out.")
                except Exception as e:
                    print(f"Error putting message on queue: {e}")
                    break
                
                # Timing control
                frame_count += 1
                elapsed = time.time() - start_time
                expected_time = frame_count * frame_time
                sleep_time = expected_time - elapsed
                
                if sleep_time > 0:
                    time.sleep(sleep_time)
                
                if frame_count % 100 == 0:
                    print(f"Streamed {frame_count} frames, FPS: {frame_count/elapsed:.2f}")
                
        except Exception as e:
            print(f"Error in desktop streaming loop: {e}")
            import traceback
            traceback.print_exc()
        finally:
            print("Desktop streaming loop finished.")
            self.running = False
            
            # Clean up processes
            if hasattr(self, 'screen_process') and self.screen_process:
                self.screen_process.terminate()
                print("Screen capture process terminated.")
            if hasattr(self, 'audio_process') and self.audio_process:
                self.audio_process.terminate()
                print("Audio capture process terminated.")
                
            # Signal broadcast loop to stop
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)

    def start_streaming(self):
        """Start streaming desktop to connected clients."""
        # Run the WebSocket server and processing loop in a new thread
        def run_server_and_processor():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            # Start the WebSocket server (which includes the broadcast loop)
            server_task = loop.create_task(self.start_websocket_server())

            # Run the desktop capture in a separate thread
            processing_thread = threading.Thread(target=self.capture_and_stream_desktop, args=(loop,))
            processing_thread.start()

            try:
                loop.run_forever()
            finally:
                print("Event loop stopping...")
                # Ensure processing thread is stopped if loop exits unexpectedly
                self.running = False
                processing_thread.join(timeout=2.0)

                # Cleanly shut down server task
                if not server_task.done():
                    server_task.cancel()
                    try:
                        loop.run_until_complete(server_task)
                    except asyncio.CancelledError:
                        pass # Expected
                loop.close()
                print("Event loop closed.")

        self.media_thread = threading.Thread(target=run_server_and_processor)
        self.media_thread.daemon = True # Allow exit even if this thread is running
        self.media_thread.start()

        return self.media_thread

class M3U8Streamer:
    def __init__(self, m3u8_url, capture_width=1280, capture_height=720, 
                 websocket_port=3245, frame_rate=30, audio_chunk_ms=40, letterbox=False):
        """Initialize M3U8 streamer for streaming from HLS sources."""
        self.m3u8_url = m3u8_url
        
        # Streaming settings
        self.capture_width = capture_width
        self.capture_height = capture_height
        self.websocket_port = websocket_port
        self.frame_rate = frame_rate
        self.audio_chunk_ms = audio_chunk_ms
        self.letterbox = letterbox
        self.running = False
        self.connected_clients = set()
        
        # Media resources
        self.media_thread = None
        self.ffmpeg_process = None
        
        # Use an asyncio queue for thread-safe broadcasting
        self.broadcast_queue = asyncio.Queue()
        
    async def websocket_handler(self, websocket):
        """Handle WebSocket connections from Godot."""
        print(f"Client connected: {websocket.remote_address}")
        self.connected_clients.add(websocket)
        try:
            await websocket.wait_closed()
        finally:
            self.connected_clients.remove(websocket)
            print(f"Client disconnected: {websocket.remote_address}")
    
    async def broadcast_loop(self):
        """Coroutine that takes messages from the queue and broadcasts them."""
        while True:
            try:
                message = await self.broadcast_queue.get()
                if message is None:
                    break

                if not self.connected_clients:
                    self.broadcast_queue.task_done()
                    continue

                disconnected = set()
                message_json = json.dumps(message)

                tasks = [ws.send(message_json) for ws in self.connected_clients]
                results = await asyncio.gather(*tasks, return_exceptions=True)

                client_list = list(self.connected_clients)
                for i, result in enumerate(results):
                    if isinstance(result, websockets.exceptions.ConnectionClosed):
                        disconnected.add(client_list[i])

                self.connected_clients -= disconnected
                self.broadcast_queue.task_done()

            except asyncio.CancelledError:
                print("Broadcast loop cancelled.")
                break
            except Exception as e:
                print(f"Error in broadcast loop: {e}")
                self.broadcast_queue.task_done()

    async def start_websocket_server(self):
        """Start the WebSocket server and the broadcast loop."""
        server = await websockets.serve(
            self.websocket_handler,
            "0.0.0.0",
            self.websocket_port
        )
        print(f"WebSocket server started on ws://0.0.0.0:{self.websocket_port}")

        broadcast_task = asyncio.create_task(self.broadcast_loop())

        try:
            await server.wait_closed()
        finally:
            await self.broadcast_queue.put(None)
            await broadcast_task
            server.close()
            await server.wait_closed()
            print("WebSocket server stopped.")

    def _setup_m3u8_capture(self):
        """Set up M3U8 stream capture using ffmpeg."""
        try:
            # FFmpeg command to capture M3U8 stream and output raw video + audio
            # Use more robust settings for HLS streams
            if self.letterbox:
                vf_filter = f"scale={self.capture_width}:{self.capture_height}:force_original_aspect_ratio=decrease,pad={self.capture_width}:{self.capture_height}:(ow-iw)/2:(oh-ih)/2"
            else:
                vf_filter = f"scale={self.capture_width}:{self.capture_height}"
            
            self.video_cmd = [
                "ffmpeg",
                "-re",  # Read input at native frame rate (important for live streams)
                "-i", self.m3u8_url,
                "-vf", vf_filter,
                "-pix_fmt", "bgr24",
                "-r", str(self.frame_rate),
                "-f", "rawvideo",
                "-an",  # No audio in video stream
                "pipe:1"
            ]
            
            self.audio_cmd = [
                "ffmpeg",
                "-re",  # Read input at native frame rate
                "-i", self.m3u8_url,
                "-vn",  # No video
                "-acodec", "pcm_s16le",  # Explicit audio codec
                "-ar", "48000",
                "-ac", "2",
                "-f", "wav",
                "pipe:1"
            ]
            
            # Add user agent and other connection options that might be required
            common_args = [
                "-user_agent", "VLC/3.0.0-LibVLC/3.0.0",
                "-reconnect", "1",
                "-reconnect_streamed", "1",
                "-reconnect_delay_max", "5",
                "-loglevel", "verbose"  # Add verbose logging
            ]
            
            # Insert common args after ffmpeg but before -i
            self.video_cmd = self.video_cmd[:1] + common_args + self.video_cmd[1:]
            self.audio_cmd = self.audio_cmd[:1] + common_args + self.audio_cmd[1:]
            
            print(f"Video command: {' '.join(self.video_cmd)}")
            print(f"Audio command: {' '.join(self.audio_cmd)}")
            
            # Start video process
            self.video_process = subprocess.Popen(
                self.video_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0  # Unbuffered
            )
            
            # Start audio process
            self.audio_process = subprocess.Popen(
                self.audio_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0  # Unbuffered
            )
            
            print(f"M3U8 stream capture started for: {self.m3u8_url}")
            
            # Wait a moment and check if processes are still running
            time.sleep(3)  # Give more time for startup
            if self.video_process.poll() is not None:
                stderr_output = self.video_process.stderr.read().decode('utf-8', errors='ignore')
                print(f"Video process failed with return code {self.video_process.returncode}")
                print(f"Video stderr: {stderr_output}")
                return False
            if self.audio_process.poll() is not None:
                stderr_output = self.audio_process.stderr.read().decode('utf-8', errors='ignore')
                print(f"Audio process failed with return code {self.audio_process.returncode}")
                print(f"Audio stderr: {stderr_output}")
                return False
                
            print("Both video and audio processes started successfully")
            return True
            
        except Exception as e:
            print(f"Error setting up M3U8 capture: {e}")
            import traceback
            traceback.print_exc()
            return False

    def capture_and_stream_m3u8(self, loop):
        """Capture and stream M3U8 content."""
        if not self._setup_m3u8_capture():
            print("M3U8 capture setup failed. Stopping.")
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)
            return

        self.running = True
        frame_size = self.capture_width * self.capture_height * 3  # BGR24 format
        frame_time = 1.0 / self.frame_rate
        
        print("Starting M3U8 streaming loop...")
        print(f"Expected frame size: {frame_size} bytes")
        try:
            frame_count = 0
            start_time = time.time()
            consecutive_failures = 0
            last_debug_time = time.time()
            
            while self.running:
                # Debug output every 5 seconds
                current_time = time.time()
                if current_time - last_debug_time > 5:
                    print(f"Debug: Still running, frame_count={frame_count}, elapsed={current_time-start_time:.1f}s")
                    print(f"Video process alive: {self.video_process.poll() is None}")
                    print(f"Audio process alive: {self.audio_process.poll() is None}")
                    last_debug_time = current_time
                
                # Check if processes are still alive
                if self.video_process.poll() is not None:
                    print(f"Video process died with return code: {self.video_process.returncode}")
                    stderr_output = self.video_process.stderr.read().decode('utf-8', errors='ignore')
                    print(f"Video stderr: {stderr_output}")
                    break
                    
                if self.audio_process.poll() is not None:
                    print(f"Audio process died with return code: {self.audio_process.returncode}")
                    stderr_output = self.audio_process.stderr.read().decode('utf-8', errors='ignore')
                    print(f"Audio stderr: {stderr_output}")
                    # Continue without audio if needed
                
                # Read raw video frame with timeout
                try:
                    print(f"Attempting to read {frame_size} bytes from video process...")
                    
                    # Try to read with a smaller chunk first to see if there's any data
                    test_chunk = self.video_process.stdout.read(1024)
                    if len(test_chunk) == 0:
                        print("No data available from video process")
                        consecutive_failures += 1
                        if consecutive_failures > 50:  # Increased threshold
                            print("Too many consecutive failures, stopping")
                            break
                        time.sleep(0.1)
                        continue
                    
                    print(f"Got {len(test_chunk)} bytes in test chunk")
                    
                    # Read the rest of the frame
                    remaining_bytes = frame_size - len(test_chunk)
                    remaining_data = self.video_process.stdout.read(remaining_bytes)
                    raw_frame = test_chunk + remaining_data
                    
                    print(f"Total frame data: {len(raw_frame)} bytes")
                    
                    if len(raw_frame) != frame_size:
                        print(f"Incomplete frame: got {len(raw_frame)} bytes, expected {frame_size}")
                        consecutive_failures += 1
                        if consecutive_failures > 50:
                            print("Too many incomplete frames, stopping")
                            break
                        continue
                    
                    consecutive_failures = 0  # Reset on success
                    print(f"Successfully read complete frame {frame_count}")
                    
                except Exception as e:
                    print(f"Error reading video frame: {e}")
                    consecutive_failures += 1
                    if consecutive_failures > 50:
                        break
                    continue

                # Convert raw frame to numpy array and reshape
                try:
                    frame = np.frombuffer(raw_frame, dtype=np.uint8).reshape(self.capture_height, self.capture_width, 3)
                    print(f"Frame reshaped successfully: {frame.shape}")
                except Exception as e:
                    print(f"Error reshaping frame: {e}")
                    continue
                
                # Read audio chunk
                audio_b64 = ""
                if hasattr(self, 'audio_process') and self.audio_process and self.audio_process.poll() is None:
                    try:
                        audio_chunk_size = int(48000 * 2 * 2 * frame_time)  # Sample rate * channels * bytes_per_sample * time
                        audio_data = self.audio_process.stdout.read(audio_chunk_size)
                        if audio_data:
                            audio_b64 = base64.b64encode(audio_data).decode('utf-8')
                            print(f"Audio chunk: {len(audio_data)} bytes -> {len(audio_b64)} b64 chars")
                    except Exception as e:
                        if frame_count % 10 == 0:  # More frequent audio error logging
                            print(f"Audio read error: {e}")
                
                # Encode video frame
                _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                video_b64 = base64.b64encode(buffer).decode('utf-8')
                print(f"Video encoded: {len(buffer)} bytes -> {len(video_b64)} b64 chars")
                
                # Create message
                message = {
                    "type": "media_chunk",
                    "audio_data": audio_b64,
                    "video_data": video_b64,
                    "timestamp_ms": int((time.time() - start_time) * 1000),
                    "chunk_info": {
                        "index": frame_count,
                        "total": -1  # Live stream, unknown total
                    }
                }
                
                print(f"Broadcasting message for frame {frame_count} to {len(self.connected_clients)} clients")
                
                # Queue for broadcasting
                future = asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(message), loop)
                try:
                    future.result(timeout=frame_time)
                    print(f"Message queued successfully for frame {frame_count}")
                except TimeoutError:
                    print("Warning: Broadcast queue put timed out.")
                except Exception as e:
                    print(f"Error putting message on queue: {e}")
                    break
                
                # Timing control
                frame_count += 1
                elapsed = time.time() - start_time
                expected_time = frame_count * frame_time
                sleep_time = expected_time - elapsed
                
                if sleep_time > 0:
                    time.sleep(sleep_time)
                
                print(f"Completed frame {frame_count}, FPS so far: {frame_count/elapsed:.2f}")
                
                # Limit debug output after first few frames
                if frame_count >= 3:
                    print("Reducing debug output after first 3 frames...")
                    break  # Remove this break to continue, but with less verbose output
                
        except Exception as e:
            print(f"Error in M3U8 streaming loop: {e}")
            import traceback
            traceback.print_exc()
        finally:
            print("M3U8 streaming loop finished.")
            self.running = False
            
            # Clean up processes
            if hasattr(self, 'video_process') and self.video_process:
                self.video_process.terminate()
                print("Video process terminated.")
            if hasattr(self, 'audio_process') and self.audio_process:
                self.audio_process.terminate()
                print("Audio process terminated.")
                
            # Signal broadcast loop to stop
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)

    def start_streaming(self):
        """Start streaming M3U8 to connected clients."""
        def run_server_and_processor():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            server_task = loop.create_task(self.start_websocket_server())
            processing_thread = threading.Thread(target=self.capture_and_stream_m3u8, args=(loop,))
            processing_thread.start()

            try:
                loop.run_forever()
            finally:
                print("Event loop stopping...")
                self.running = False
                processing_thread.join(timeout=2.0)

                if not server_task.done():
                    server_task.cancel()
                    try:
                        loop.run_until_complete(server_task)
                    except asyncio.CancelledError:
                        pass
                loop.close()
                print("Event loop closed.")

        self.media_thread = threading.Thread(target=run_server_and_processor)
        self.media_thread.daemon = True
        self.media_thread.start()

        return self.media_thread

class VLCStreamer:
    def __init__(self, stream_url, capture_width=1280, capture_height=720, 
                 websocket_port=3245, frame_rate=30, audio_chunk_ms=40, letterbox=False):
        """Initialize VLC-based streamer for streaming from any URL VLC supports."""
        self.stream_url = stream_url
        
        # Streaming settings
        self.capture_width = capture_width
        self.capture_height = capture_height
        self.websocket_port = websocket_port
        self.frame_rate = frame_rate
        self.audio_chunk_ms = audio_chunk_ms
        self.letterbox = letterbox
        self.running = False
        self.connected_clients = set()
        
        # Media resources
        self.media_thread = None
        self.vlc_process = None
        self.video_process = None
        self.audio_process = None
        
        # Detect operating system
        self.os_type = platform.system().lower()
        print(f"Detected OS: {self.os_type}")
        
        # Use an asyncio queue for thread-safe broadcasting
        self.broadcast_queue = asyncio.Queue()
        
        # Register cleanup function
        atexit.register(self.cleanup)
        
    def cleanup(self):
        """Clean up VLC and FFmpeg processes."""
        print("Cleaning up processes...")
        if hasattr(self, 'vlc_process') and self.vlc_process:
            try:
                self.vlc_process.terminate()
                self.vlc_process.wait(timeout=5)
                print("VLC process terminated.")
            except:
                try:
                    self.vlc_process.kill()
                    print("VLC process killed.")
                except:
                    pass
                    
        if hasattr(self, 'video_process') and self.video_process:
            try:
                self.video_process.terminate()
                print("Video capture process terminated.")
            except:
                pass
                
        if hasattr(self, 'audio_process') and self.audio_process:
            try:
                self.audio_process.terminate()
                print("Audio capture process terminated.")
            except:
                pass
        
    async def websocket_handler(self, websocket):
        """Handle WebSocket connections from Godot."""
        print(f"Client connected: {websocket.remote_address}")
        self.connected_clients.add(websocket)
        try:
            await websocket.wait_closed()
        finally:
            self.connected_clients.remove(websocket)
            print(f"Client disconnected: {websocket.remote_address}")
    
    async def broadcast_loop(self):
        """Coroutine that takes messages from the queue and broadcasts them."""
        while True:
            try:
                message = await self.broadcast_queue.get()
                if message is None:
                    break

                if not self.connected_clients:
                    self.broadcast_queue.task_done()
                    continue

                disconnected = set()
                message_json = json.dumps(message)

                tasks = [ws.send(message_json) for ws in self.connected_clients]
                results = await asyncio.gather(*tasks, return_exceptions=True)

                client_list = list(self.connected_clients)
                for i, result in enumerate(results):
                    if isinstance(result, websockets.exceptions.ConnectionClosed):
                        disconnected.add(client_list[i])

                self.connected_clients -= disconnected
                self.broadcast_queue.task_done()

            except asyncio.CancelledError:
                print("Broadcast loop cancelled.")
                break
            except Exception as e:
                print(f"Error in broadcast loop: {e}")
                self.broadcast_queue.task_done()

    async def start_websocket_server(self):
        """Start the WebSocket server and the broadcast loop."""
        server = await websockets.serve(
            self.websocket_handler,
            "0.0.0.0",
            self.websocket_port
        )
        print(f"WebSocket server started on ws://0.0.0.0:{self.websocket_port}")

        broadcast_task = asyncio.create_task(self.broadcast_loop())

        try:
            await server.wait_closed()
        finally:
            await self.broadcast_queue.put(None)
            await broadcast_task
            server.close()
            await server.wait_closed()
            print("WebSocket server stopped.")

    def _setup_vlc_stream(self):
        """Set up VLC to stream the URL to HTTP for FFmpeg to capture."""
        try:
            # VLC HTTP streaming port
            vlc_http_port = 8554
            
            if self.os_type == "windows":
                vlc_cmd = [
                    "vlc",
                    self.stream_url,
                    "--intf", "dummy",  # No interface
                    "--no-video-title-show",  # Don't show video title
                    "--sout", f"#http{{mux=ts,dst=:{vlc_http_port}/stream}}",
                    "--sout-keep"
                ]
            else:  # macOS/Linux
                vlc_cmd = [
                    "vlc",
                    self.stream_url,
                    "--intf", "dummy",
                    "--no-video-title-show",
                    "--sout", f"#http{{mux=ts,dst=:{vlc_http_port}/stream}}",
                    "--sout-keep"
                ]
            
            print(f"Starting VLC with command: {' '.join(vlc_cmd)}")
            
            # Start VLC process
            if self.os_type == "windows":
                self.vlc_process = subprocess.Popen(
                    vlc_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
                )
            else:
                self.vlc_process = subprocess.Popen(
                    vlc_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
            
            # Wait for VLC to start streaming
            print("Waiting for VLC to start streaming...")
            time.sleep(10)  # Increased wait time
            
            # Check if VLC is still running
            if self.vlc_process.poll() is not None:
                stderr_output = self.vlc_process.stderr.read().decode('utf-8', errors='ignore')
                stdout_output = self.vlc_process.stdout.read().decode('utf-8', errors='ignore')
                print(f"VLC failed to start. Return code: {self.vlc_process.returncode}")
                print(f"VLC stderr: {stderr_output}")
                print(f"VLC stdout: {stdout_output}")
                return False
            
            # Test if the HTTP stream is available
            try:
                print(f"Testing HTTP stream at http://localhost:{vlc_http_port}/stream")
                response = urllib.request.urlopen(f"http://localhost:{vlc_http_port}/stream", timeout=5)
                print(f"HTTP stream is available. Response code: {response.getcode()}")
                response.close()
            except Exception as e:
                print(f"HTTP stream not yet available: {e}")
                print("Waiting a bit more...")
                time.sleep(5)
                try:
                    response = urllib.request.urlopen(f"http://localhost:{vlc_http_port}/stream", timeout=5)
                    print(f"HTTP stream is now available. Response code: {response.getcode()}")
                    response.close()
                except Exception as e2:
                    print(f"HTTP stream still not available: {e2}")
                    return False
            
            # Now set up FFmpeg to capture from VLC's HTTP stream
            if self.letterbox:
                vf_filter = f"scale={self.capture_width}:{self.capture_height}:force_original_aspect_ratio=decrease,pad={self.capture_width}:{self.capture_height}:(ow-iw)/2:(oh-ih)/2"
            else:
                vf_filter = f"scale={self.capture_width}:{self.capture_height}"
            
            self.video_cmd = [
                "ffmpeg",
                "-i", f"http://localhost:{vlc_http_port}/stream",
                "-vf", vf_filter,
                "-pix_fmt", "bgr24",
                "-r", str(self.frame_rate),
                "-f", "rawvideo",
                "-an",  # No audio in video stream
                "pipe:1"
            ]
            
            self.audio_cmd = [
                "ffmpeg",
                "-i", f"http://localhost:{vlc_http_port}/stream",
                "-vn",  # No video
                "-acodec", "pcm_s16le",
                "-ar", "48000",
                "-ac", "2",
                "-f", "wav",
                "pipe:1"
            ]
            
            print(f"Video command: {' '.join(self.video_cmd)}")
            print(f"Audio command: {' '.join(self.audio_cmd)}")
            
            # Start FFmpeg processes
            if self.os_type == "windows":
                self.video_process = subprocess.Popen(
                    self.video_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0,
                    creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
                )
                
                self.audio_process = subprocess.Popen(
                    self.audio_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0,
                    creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
                )
            else:
                self.video_process = subprocess.Popen(
                    self.video_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0
                )
                
                self.audio_process = subprocess.Popen(
                    self.audio_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0
                )
            
            # Wait a moment and check if FFmpeg processes are still running
            time.sleep(3)
            if self.video_process.poll() is not None:
                stderr_output = self.video_process.stderr.read().decode('utf-8', errors='ignore')
                print(f"Video process failed with return code {self.video_process.returncode}")
                print(f"Video stderr: {stderr_output}")
                return False
            if self.audio_process.poll() is not None:
                stderr_output = self.audio_process.stderr.read().decode('utf-8', errors='ignore')
                print(f"Audio process failed with return code {self.audio_process.returncode}")
                print(f"Audio stderr: {stderr_output}")
                return False
                
            print("VLC and FFmpeg processes started successfully")
            return True
            
        except Exception as e:
            print(f"Error setting up VLC stream: {e}")
            import traceback
            traceback.print_exc()
            return False

    def capture_and_stream_vlc(self, loop):
        """Capture and stream VLC output."""
        if not self._setup_vlc_stream():
            print("VLC stream setup failed. Stopping.")
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)
            return

        self.running = True
        frame_size = self.capture_width * self.capture_height * 3  # BGR24 format
        frame_time = 1.0 / self.frame_rate
        
        print("Starting VLC streaming loop...")
        print(f"Expected frame size: {frame_size} bytes")
        try:
            frame_count = 0
            start_time = time.time()
            consecutive_failures = 0
            last_debug_time = time.time()
            
            while self.running:
                # Debug output every 10 seconds (reduced frequency)
                current_time = time.time()
                if current_time - last_debug_time > 10:
                    print(f"Debug: Still running, frame_count={frame_count}, elapsed={current_time-start_time:.1f}s")
                    print(f"VLC process alive: {self.vlc_process.poll() is None}")
                    print(f"Video process alive: {self.video_process.poll() is None}")
                    print(f"Audio process alive: {self.audio_process.poll() is None}")
                    last_debug_time = current_time
                
                # Check if processes are still alive
                if self.vlc_process.poll() is not None:
                    print(f"VLC process died with return code: {self.vlc_process.returncode}")
                    break
                    
                if self.video_process.poll() is not None:
                    print(f"Video process died with return code: {self.video_process.returncode}")
                    stderr_output = self.video_process.stderr.read().decode('utf-8', errors='ignore')
                    print(f"Video stderr: {stderr_output}")
                    break
                    
                if self.audio_process.poll() is not None:
                    print(f"Audio process died with return code: {self.audio_process.returncode}")
                    stderr_output = self.audio_process.stderr.read().decode('utf-8', errors='ignore')
                    print(f"Audio stderr: {stderr_output}")
                    # Continue without audio if needed
                
                # Read raw video frame in chunks
                try:
                    raw_frame = b""
                    bytes_needed = frame_size
                    max_attempts = 100  # Prevent infinite loops
                    attempts = 0
                    
                    while len(raw_frame) < frame_size and attempts < max_attempts:
                        chunk_size = min(32768, bytes_needed)  # Read in 32KB chunks
                        chunk = self.video_process.stdout.read(chunk_size)
                        
                        if len(chunk) == 0:
                            print("No more data available from video process")
                            break
                            
                        raw_frame += chunk
                        bytes_needed = frame_size - len(raw_frame)
                        attempts += 1
                        
                        if frame_count < 3:  # Debug first few frames
                            print(f"Read chunk: {len(chunk)} bytes, total: {len(raw_frame)}/{frame_size}")
                    
                    if len(raw_frame) != frame_size:
                        if frame_count < 3:
                            print(f"Incomplete frame after {attempts} attempts: got {len(raw_frame)} bytes, expected {frame_size}")
                        consecutive_failures += 1
                        if consecutive_failures > 50:
                            print("Too many incomplete frames, stopping")
                            break
                        continue
                    
                    consecutive_failures = 0  # Reset on success
                    if frame_count < 3:
                        print(f"Successfully read complete frame {frame_count}")
                    
                except Exception as e:
                    print(f"Error reading video frame: {e}")
                    consecutive_failures += 1
                    if consecutive_failures > 50:
                        break
                    continue

                # Convert raw frame to numpy array and reshape
                try:
                    frame = np.frombuffer(raw_frame, dtype=np.uint8).reshape(self.capture_height, self.capture_width, 3)
                    if frame_count < 3:
                        print(f"Frame reshaped successfully: {frame.shape}")
                except Exception as e:
                    print(f"Error reshaping frame: {e}")
                    continue
                
                # Read audio chunk
                audio_b64 = ""
                if hasattr(self, 'audio_process') and self.audio_process and self.audio_process.poll() is None:
                    try:
                        audio_chunk_size = int(48000 * 2 * 2 * frame_time)
                        
                        # Read audio in chunks too
                        audio_data = b""
                        audio_bytes_needed = audio_chunk_size
                        audio_attempts = 0
                        max_audio_attempts = 10
                        
                        while len(audio_data) < audio_chunk_size and audio_attempts < max_audio_attempts:
                            audio_chunk = self.audio_process.stdout.read(min(4096, audio_bytes_needed))
                            if len(audio_chunk) == 0:
                                break
                            audio_data += audio_chunk
                            audio_bytes_needed = audio_chunk_size - len(audio_data)
                            audio_attempts += 1
                        
                        if audio_data:
                            audio_b64 = base64.b64encode(audio_data).decode('utf-8')
                            if frame_count < 3:
                                print(f"Audio chunk: {len(audio_data)} bytes")
                    except Exception as e:
                        if frame_count % 100 == 0:
                            print(f"Audio read error: {e}")
                
                # Encode video frame
                _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                video_b64 = base64.b64encode(buffer).decode('utf-8')
                if frame_count < 3:
                    print(f"Video encoded: {len(buffer)} bytes")
                
                # Create message
                message = {
                    "type": "media_chunk",
                    "audio_data": audio_b64,
                    "video_data": video_b64,
                    "timestamp_ms": int((time.time() - start_time) * 1000),
                    "chunk_info": {
                        "index": frame_count,
                        "total": -1
                    }
                }
                
                if frame_count < 3:
                    print(f"Broadcasting message for frame {frame_count}")
                
                # Queue for broadcasting
                future = asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(message), loop)
                try:
                    future.result(timeout=frame_time)
                except TimeoutError:
                    print("Warning: Broadcast queue put timed out.")
                except Exception as e:
                    print(f"Error putting message on queue: {e}")
                    break
                
                # Timing control
                frame_count += 1
                elapsed = time.time() - start_time
                expected_time = frame_count * frame_time
                sleep_time = expected_time - elapsed
                
                if sleep_time > 0:
                    time.sleep(sleep_time)
                
                if frame_count % 100 == 0:
                    print(f"Completed frame {frame_count}, FPS so far: {frame_count/elapsed:.2f}")
                    
        except Exception as e:
            print(f"Error in VLC streaming loop: {e}")
            import traceback
            traceback.print_exc()
        finally:
            print("VLC streaming loop finished.")
            self.running = False
            self.cleanup()
            
            # Signal broadcast loop to stop
            asyncio.run_coroutine_threadsafe(self.broadcast_queue.put(None), loop)

    def start_streaming(self):
        """Start streaming from VLC to connected clients."""
        def run_server_and_processor():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            server_task = loop.create_task(self.start_websocket_server())
            processing_thread = threading.Thread(target=self.capture_and_stream_vlc, args=(loop,))
            processing_thread.start()

            try:
                loop.run_forever()
            finally:
                print("Event loop stopping...")
                self.running = False
                processing_thread.join(timeout=2.0)

                if not server_task.done():
                    server_task.cancel()
                    try:
                        loop.run_until_complete(server_task)
                    except asyncio.CancelledError:
                        pass
                loop.close()
                print("Event loop closed.")

        self.media_thread = threading.Thread(target=run_server_and_processor)
        self.media_thread.daemon = True
        self.media_thread.start()

        return self.media_thread

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Media Streamer')
    parser.add_argument('-m3u8', '--m3u8-url', type=str, 
                       help='Stream from M3U8 URL (e.g., HLS stream)')
    parser.add_argument('-vlc', '--vlc-url', type=str,
                       help='Stream any URL through VLC (most reliable)')
    parser.add_argument('--desktop', action='store_true', 
                       help='Stream desktop capture')
    parser.add_argument('--video', type=str, 
                       help='Stream from video file')
    parser.add_argument('--port', type=int, default=3245,
                       help='WebSocket port (default: 3245)')
    parser.add_argument('--width', type=int, default=2560,
                       help='Capture width (default: 1680)')
    parser.add_argument('--height', type=int, default=1080,
                       help='Capture height (default: 720)')
    parser.add_argument('--fps', type=int, default=30,
                       help='Frame rate (default: 30)')
    parser.add_argument('--letterbox', action='store_true',
                       help='Preserve aspect ratio with letterboxing/pillarboxing (adds black bars)')
    
    args = parser.parse_args()

    # Improve sleep/timer accuracy on Windows (Solution B) so A/V pacing matches macOS.
    # No-op on macOS, so the macOS behaviour is unchanged.
    _enable_high_res_timer()

    # Set up signal handler for graceful shutdown
    def signal_handler(sig, frame):
        print('\nReceived interrupt signal. Shutting down gracefully...')
        if 'streamer' in locals():
            streamer.cleanup()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        if args.vlc_url:
            print(f"Starting VLC Streaming: {args.vlc_url}")
            streamer = VLCStreamer(
                stream_url=args.vlc_url,
                capture_width=args.width,
                capture_height=args.height,
                websocket_port=args.port,
                frame_rate=args.fps,
                letterbox=args.letterbox
            )
            media_thread = streamer.start_streaming()
        elif args.m3u8_url:
            print(f"Starting M3U8 Streaming: {args.m3u8_url}")
            streamer = M3U8Streamer(
                m3u8_url=args.m3u8_url,
                capture_width=args.width,
                capture_height=args.height,
                websocket_port=args.port,
                frame_rate=args.fps,
                letterbox=args.letterbox
            )
            media_thread = streamer.start_streaming()
        elif args.desktop:
            print("Starting Desktop Streaming...")
            streamer = DesktopStreamer(
                capture_width=args.width,
                capture_height=args.height,
                websocket_port=args.port,
                frame_rate=args.fps,
                letterbox=args.letterbox
            )
            media_thread = streamer.start_streaming()
        elif args.video:
            print(f"Starting Video File Streaming: {args.video}")
            streamer = DirectMediaStreamer(
                video_path=args.video,
                capture_width=args.width,
                capture_height=args.height,
                websocket_port=args.port,
                letterbox=args.letterbox
            )
            media_thread = streamer.stream_media()
        else:
            # Default behavior - desktop streaming
            print("No specific mode selected. Starting Desktop Streaming...")
            streamer = DesktopStreamer(
                capture_width=args.width,
                capture_height=args.height,
                websocket_port=args.port,
                frame_rate=args.fps,
                letterbox=args.letterbox
            )
            media_thread = streamer.start_streaming()

        print("Streaming started... Press Ctrl+C to exit.")
        while media_thread.is_alive():
            time.sleep(1)

    except KeyboardInterrupt:
        print("\nCtrl+C received. Exiting...")
        if 'streamer' in locals():
            streamer.cleanup()
    except Exception as e:
        print(f"Fatal Error: {e}")
        import traceback
        traceback.print_exc()
        if 'streamer' in locals():
            streamer.cleanup()

    print("Main thread finished.")