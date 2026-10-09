#!/usr/bin/env python

import asyncio
import websockets
import json
import subprocess
import threading
import time
import base64
import os
import platform
import argparse
import aiohttp

class VoiceMicrophoneClient:
    def __init__(self, username, password, room="default", server_url="wss://example.com/voice", **kwargs):
        """Initialize voice microphone client."""
        self.username = username
        self.password = password
        self.room = room
        self.server_url = server_url
        self.sample_rate = kwargs.get('sample_rate', 48000)
        self.channels = kwargs.get('channels', 2)
        self.audio_chunk_ms = kwargs.get('audio_chunk_ms', 40)
        self.running = False
        self.registered = False
        self.websocket = None
        self.audio_process = None
        self.auth_token = None
        
        # Authentication API endpoint (separate from main server)
        self.auth_url = kwargs.get('auth_url', 'http://127.0.0.1:8080/api/auth')
        
        # Audio device settings
        self.audio_device = kwargs.get('audio_device', None)  # None = auto-detect
        
        # Audio capture settings
        self.bytes_per_chunk = int((self.sample_rate * self.channels * 2 * self.audio_chunk_ms) / 1000)
        
    @staticmethod
    def list_audio_devices():
        """List available audio input devices"""
        print("Listing available audio input devices...")
        
        if platform.system() == "Windows":
            print("\nWindows DirectShow devices:")
            try:
                result = subprocess.run([
                    "ffmpeg", "-f", "dshow", "-list_devices", "true", "-i", "dummy"
                ], capture_output=True, text=True)
                # ffmpeg outputs device list to stderr, not stdout
                output = result.stderr if result.stderr else result.stdout
                print(output)
            except Exception as e:
                print(f"Error listing Windows devices: {e}")
                
        elif platform.system() == "Darwin":  # macOS
            print("\nmacOS AVFoundation devices:")
            try:
                result = subprocess.run([
                    "ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""
                ], capture_output=True, text=True)
                # ffmpeg outputs device list to stderr, not stdout
                output = result.stderr if result.stderr else result.stdout
                print(output)
                print("\nTo use a specific device, use: --audio-device ':N' where N is the device number")
                print("Example: --audio-device ':1' for device [1]")
            except Exception as e:
                print(f"Error listing macOS devices: {e}")
                
        else:  # Linux
            print("\nLinux ALSA devices:")
            try:
                result = subprocess.run([
                    "arecord", "-l"
                ], capture_output=True, text=True)
                print(result.stdout)
                print("\nTo use a specific device, use: --audio-device 'hw:X,Y' where X is card number and Y is device number")
                print("Example: --audio-device 'hw:1,0' for card 1, device 0")
            except Exception as e:
                print(f"Error listing Linux devices: {e}")
                try:
                    # Fallback to ffmpeg
                    result = subprocess.run([
                        "ffmpeg", "-f", "alsa", "-list_devices", "true", "-i", "dummy"
                    ], capture_output=True, text=True)
                    # ffmpeg outputs device list to stderr, not stdout
                    output = result.stderr if result.stderr else result.stdout
                    print(output)
                except Exception as e2:
                    print(f"Error listing devices with ffmpeg: {e2}")
    
    async def authenticate_via_http(self):
        """Authenticate via separate HTTP API endpoint"""
        try:
            async with aiohttp.ClientSession() as session:
                auth_data = {
                    "username": self.username,
                    "password": self.password,
                    "service": "voice_client"  # Identify this as voice client auth
                }
                
                async with session.post(self.auth_url, json=auth_data) as response:
                    if response.status == 200:
                        result = await response.json()
                        if result.get("success"):
                            self.auth_token = result.get("token")
                            print(f"HTTP authentication successful for {self.username}")
                            return True
                        else:
                            print(f"Authentication failed: {result.get('message', 'Unknown error')}")
                            return False
                    else:
                        print(f"Authentication HTTP error: {response.status}")
                        return False
                        
        except Exception as e:
            print(f"Authentication error: {e}")
            print(f"Note: Voice client uses separate authentication endpoint at {self.auth_url}")
            # For now, allow to continue without authentication for testing
            print("Continuing without authentication for testing purposes...")
            return True

    async def keepalive_task(self):
        """Send periodic pings to keep connection alive"""
        while self.registered and hasattr(self, 'websocket'):
            try:
                await asyncio.sleep(10)  # Send ping every 10 seconds (more frequent)
                if self.registered and hasattr(self, 'websocket'):
                    ping_message = {
                        "type": "ping",
                        "timestamp": int(time.time() * 1000)
                    }
                    await self.websocket.send(json.dumps(ping_message))
                    print("Sent ping to voice server")
            except Exception as e:
                print(f"Error in keepalive: {e}")
                break

    async def connect_to_voice_server(self):
        """Connect to voice chat server"""
        try:
            print(f"Connecting to voice server: {self.server_url}")
            self.websocket = await websockets.connect(self.server_url)
            
            # Register with voice server
            registration = {
                "type": "register",
                "username": self.username,
                "room": self.room,
                "user_type": "streamer"  # This client streams microphone data
            }
            
            # Include auth token if we have one
            if self.auth_token:
                registration["auth_token"] = self.auth_token
            
            await self.websocket.send(json.dumps(registration))
            
            # Wait for confirmation
            response = await self.websocket.recv()
            response_data = json.loads(response)
            
            if response_data.get("type") == "registered":
                self.registered = True
                print(f"Successfully registered and authenticated with voice server as {self.username}")
                
                # Start keepalive task
                asyncio.create_task(self.keepalive_task())
                return True
            elif response_data.get("type") == "auth_failed":
                print(f"Authentication failed: {response_data.get('message', 'Invalid credentials')}")
                return False
            else:
                print(f"Registration failed: {response_data}")
                return False
                
        except Exception as e:
            print(f"Failed to connect to voice server: {e}")
            return False

    async def handle_server_messages(self):
        """Handle incoming messages from the voice server"""
        try:
            while self.registered and hasattr(self, 'websocket'):
                try:
                    message = await self.websocket.recv()
                    data = json.loads(message)
                    
                    if data.get('type') == 'ping':
                        # Server sent ping, respond with pong
                        pong_message = {
                            "type": "pong",
                            "timestamp": int(time.time() * 1000)
                        }
                        await self.websocket.send(json.dumps(pong_message))
                        print("Responded to server ping with pong")
                        
                    elif data.get('type') == 'pong':
                        # Server responded to our ping
                        print("Received pong from server")
                        
                    elif data.get('type') == 'user_joined':
                        print(f"User joined room: {data.get('username', 'Unknown')}")
                        
                    elif data.get('type') == 'user_left':
                        print(f"User left room: {data.get('username', 'Unknown')}")
                        
                    else:
                        print(f"Received unhandled message type: {data.get('type')}")
                        
                except json.JSONDecodeError:
                    print("Received invalid JSON from voice server")
                except Exception as e:
                    print(f"Error handling server message: {e}")
                    break
                    
        except Exception as e:
            print(f"Error in message handler: {e}")

    async def send_audio_chunk(self, audio_data):
        """Send audio chunk to voice server"""
        if not self.registered or not hasattr(self, 'websocket'):
            return
            
        # Encode audio data as base64
        audio_base64 = base64.b64encode(audio_data).decode('utf-8')
        
        audio_message = {
            "type": "audio_chunk",
            "audio_data": audio_base64,
            "timestamp_ms": int(time.time() * 1000),
            "chunk_info": {
                "sample_rate": self.sample_rate,
                "channels": self.channels,
                "chunk_ms": self.audio_chunk_ms
            }
        }
        
        try:
            await self.websocket.send(json.dumps(audio_message))
        except Exception as e:
            print(f"Error sending audio chunk: {e}")

    def _setup_microphone_capture(self):
        """Set up microphone capture based on OS"""
        if platform.system() == "Windows":
            return self._setup_windows_microphone()
        elif platform.system() == "Darwin":  # macOS
            return self._setup_macos_microphone()
        else:  # Linux
            return self._setup_linux_microphone()
    
    def _setup_windows_microphone(self):
        """Set up microphone capture for Windows using DirectShow."""
        if self.audio_device:
            # Use specified device
            devices_to_try = [self.audio_device]
        else:
            # Try default devices
            devices_to_try = [
                "audio=Mikrofon (3- AKG C44-USB Microphone)",
                "audio=Headset Microphone (Oculus Virtual Audio Device)",
                "audio=CABLE Output (VB-Audio Virtual Cable)",
                "audio=Microphone",
                "audio=Default"
            ]
        
        for device in devices_to_try:
            try:
                cmd = [
                    "ffmpeg", "-f", "dshow", "-i", device,
                    "-ar", str(self.sample_rate), "-ac", str(self.channels),
                    "-f", "s16le", "-acodec", "pcm_s16le", "-"
                ]
                
                print(f"Trying Windows microphone capture with device: {device}")
                self.audio_process = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                
                # Check if process started successfully
                import time
                time.sleep(0.5)  # Give it a moment to start
                if self.audio_process.poll() is not None:
                    # Process terminated, check stderr
                    stderr_output = self.audio_process.stderr.read().decode('utf-8')
                    print(f"FFmpeg error with {device}: {stderr_output}")
                    continue
                
                print(f"Successfully started Windows microphone capture with device: {device}")
                return True
            except Exception as e:
                print(f"Failed to start Windows microphone with {device}: {e}")
                continue
        
        print("Failed to start any Windows microphone device")
        return False
    
    def _setup_macos_microphone(self):
        """Set up microphone capture for macOS using AVFoundation."""
        # Use specified device or default to :0
        if self.audio_device:
            # Auto-format device for AVFoundation if it's just a number
            if self.audio_device.isdigit():
                device = f":{self.audio_device}"
            else:
                device = self.audio_device
        else:
            device = ":0"
        
        try:
            cmd = [
                "ffmpeg", "-f", "avfoundation", "-i", device,
                "-ar", str(self.sample_rate), "-ac", str(self.channels),
                "-f", "s16le", "-acodec", "pcm_s16le", "-"
            ]
            
            print(f"Starting macOS microphone capture with device: {device}")
            self.audio_process = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            
            # Check if process started successfully
            import time
            time.sleep(0.5)  # Give it a moment to start
            if self.audio_process.poll() is not None:
                # Process terminated, check stderr
                stderr_output = self.audio_process.stderr.read().decode('utf-8')
                print(f"FFmpeg error: {stderr_output}")
                return False
                
            print(f"Successfully started macOS microphone capture with device: {device}")
            return True
        except Exception as e:
            print(f"Failed to start macOS microphone: {e}")
            return False
    
    def _setup_linux_microphone(self):
        """Set up microphone capture for Linux using ALSA."""
        # Use specified device or default to "default"
        device = self.audio_device if self.audio_device else "default"
        
        try:
            cmd = [
                "ffmpeg", "-f", "alsa", "-i", device,
                "-ar", str(self.sample_rate), "-ac", str(self.channels),
                "-f", "s16le", "-acodec", "pcm_s16le", "-"
            ]
            
            print(f"Starting Linux microphone capture with device: {device}")
            self.audio_process = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            
            # Check if process started successfully
            import time
            time.sleep(0.5)  # Give it a moment to start
            if self.audio_process.poll() is not None:
                # Process terminated, check stderr
                stderr_output = self.audio_process.stderr.read().decode('utf-8')
                print(f"FFmpeg error: {stderr_output}")
                return False
                
            print(f"Successfully started Linux microphone capture with device: {device}")
            return True
        except Exception as e:
            print(f"Failed to start Linux microphone: {e}")
            return False

    async def start_websocket_server(self):
        """Handle WebSocket connection and audio streaming"""
        # First authenticate via HTTP
        if not await self.authenticate_via_http():
            return
        
        # Connect to voice server
        if not await self.connect_to_voice_server():
            return
        
        # Start microphone capture
        if not self._setup_microphone_capture():
            print("Failed to set up microphone capture")
            return
        
        self.running = True
        print(f"Voice microphone client started for {self.username}")
        print("Press Ctrl+C to stop...")
        
        try:
            # Start message handling task
            message_task = asyncio.create_task(self.handle_server_messages())
            
            # Keep connection alive and process incoming messages
            await asyncio.gather(message_task, return_exceptions=True)
        except KeyboardInterrupt:
            print("\nShutting down...")
        finally:
            await self.cleanup()

    async def audio_capture_loop(self):
        """Capture and send audio chunks"""
        while self.running and self.audio_process:
            try:
                # Read audio chunk
                audio_chunk = self.audio_process.stdout.read(self.bytes_per_chunk)
                if not audio_chunk:
                    break
                
                # Send to voice server
                await self.send_audio_chunk(audio_chunk)
                
                # Small delay to control chunk rate
                await asyncio.sleep(self.audio_chunk_ms / 1000.0)
                
            except Exception as e:
                print(f"Error in audio capture: {e}")
                break

    async def cleanup(self):
        """Clean up resources"""
        self.running = False
        self.registered = False
        
        if self.audio_process:
            self.audio_process.terminate()
            self.audio_process = None
            
        if hasattr(self, 'websocket'):
            await self.websocket.close()

    async def run(self):
        """Main run function"""
        # Start WebSocket connection
        websocket_task = asyncio.create_task(self.start_websocket_server())
        
        # Wait a moment for connection to establish
        await asyncio.sleep(1)
        
        # Start audio capture if connected
        if self.running and self.registered:
            audio_task = asyncio.create_task(self.audio_capture_loop())
            
            # Wait for either task to complete
            await asyncio.gather(websocket_task, audio_task, return_exceptions=True)
        else:
            await websocket_task

async def main():
    parser = argparse.ArgumentParser(description='Voice Microphone Client')
    parser.add_argument('--username', type=str, required=True, help='Username for authentication')
    parser.add_argument('--password', type=str, required=True, help='Password for authentication')
    parser.add_argument('--room', type=str, default='default', help='Room to join (default: default)')
    parser.add_argument('--server', type=str, required=True, help='Voice chat server URL, e.g. wss://example.com/voice')
    parser.add_argument('--sample-rate', type=int, default=48000, help='Audio sample rate (default: 48000)')
    parser.add_argument('--channels', type=int, default=2, help='Audio channels (default: 2)')
    parser.add_argument('--chunk-ms', type=int, default=40, help='Audio chunk size in ms (default: 40)')
    parser.add_argument('--auth-url', type=str, default='http://127.0.0.1:8080/api/auth', help='Authentication API endpoint')
    parser.add_argument('--audio-device', type=str, help='Audio input device (use --list-devices to see available options)')
    parser.add_argument('--list-devices', action='store_true', help='List available audio input devices and exit')
    
    args = parser.parse_args()
    
    client = VoiceMicrophoneClient(
        username=args.username,
        password=args.password,
        room=args.room,
        server_url=args.server,
        sample_rate=args.sample_rate,
        channels=args.channels,
        audio_chunk_ms=args.chunk_ms,
        auth_url=args.auth_url,
        audio_device=args.audio_device
    )
    
    try:
        await client.run()
    except KeyboardInterrupt:
        print("\nShutting down...")
        await client.cleanup()

if __name__ == "__main__":
    # Handle device listing before entering async context
    import sys
    if '--list-devices' in sys.argv:
        VoiceMicrophoneClient.list_audio_devices()
        sys.exit(0)
    
    asyncio.run(main())
