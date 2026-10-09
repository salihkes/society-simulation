const video = document.getElementById('stream');
let pc = null;
let dc = null;

// Auth Handling - Defined early
window.attemptLogin = function() {
    const pass = document.getElementById('passphrase').value;
    document.getElementById('login-error').style.display = 'none';
    if (pass) {
        start(pass);
    }
};

async function start(authKey) {
    try {
        pc = new RTCPeerConnection();
        
        dc = pc.createDataChannel('input');
        dc.onopen = () => {
            console.log('Connected. Click to capture mouse.');
        };
        dc.onmessage = (e) => console.log('Server:', e.data);


        pc.ontrack = (evt) => {
            if (evt.track.kind === 'video') {
                const [stream] = evt.streams;
                if (stream) {
                    video.srcObject = stream;
                    // Safari (especially on iOS / recent versions) may block autoplay
                    // even for muted WebRTC streams unless play() is called explicitly.
                    const playPromise = video.play();
                    if (playPromise !== undefined) {
                        playPromise.catch((err) => {
                            console.warn('Video autoplay was blocked, will start on user gesture.', err);
                        });
                    }
                }
            }
        };

        // Add transceiver to ensure video m-line is present in offer
        pc.addTransceiver('video', { direction: 'recvonly' });

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);

        const response = await fetch('/offer', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                sdp: pc.localDescription.sdp,
                type: pc.localDescription.type,
                auth: authKey
            })
        });

        if (response.status === 401 || response.status === 403) {
            throw new Error("Unauthorized");
        }

        const answer = await response.json();
        await pc.setRemoteDescription(answer);
        
        // Hide login overlay on success
        document.getElementById('login-overlay').classList.add('hidden');
        
    } catch (e) {
        console.error('Error connecting: ' + e);
        if (e.message === "Unauthorized") {
             const errorDiv = document.getElementById('login-error');
             errorDiv.style.display = 'block';
             errorDiv.textContent = "Incorrect Passphrase";
        } else {
             alert("Connection failed: " + e);
        }
        if (pc) {
            pc.close();
            pc = null;
        }
    }
}

// Input Handling
function send(data) {
    if (dc && dc.readyState === 'open') {
        dc.send(JSON.stringify(data));
    }
}

// Mouse Locking
const requestPointerLock = async () => {
    if (document.pointerLockElement !== video) {
        try {
            await video.requestPointerLock();
        } catch (e) {
            console.error(e);
        }
    }
};

// --- INPUT HANDLING ---

// POINTER LOCK + Start video on user gesture (helps Safari autoplay policy)
video.addEventListener('click', async () => {
    try {
        if (video.paused) {
            await video.play();
        }
    } catch (e) {
        console.error('Error starting video playback on click:', e);
    }
    requestPointerLock();
});

document.addEventListener('pointerlockchange', () => {
    if (document.pointerLockElement === video) {
        send({ type: 'mouse_mode', captured: true });
    } else {
        send({ type: 'mouse_mode', captured: false });
    }
});

// Rate limiting for mouse motion
let mouseMotionAccumulator = { dx: 0, dy: 0, x: 0, y: 0, hasData: false };
const MOUSE_SEND_INTERVAL_MS = 33; // ~30 packets/sec to reduce congestion

setInterval(() => {
    if (mouseMotionAccumulator.hasData) {
        send({
            type: 'mouse_motion',
            x: mouseMotionAccumulator.x,
            y: mouseMotionAccumulator.y,
            dx: mouseMotionAccumulator.dx,
            dy: mouseMotionAccumulator.dy,
        });
        // Reset accumulated deltas
        mouseMotionAccumulator.dx = 0;
        mouseMotionAccumulator.dy = 0;
        mouseMotionAccumulator.hasData = false;
    }
}, MOUSE_SEND_INTERVAL_MS);

// MOUSE (Desktop)
document.addEventListener('mousemove', (e) => {
    if (document.pointerLockElement !== video) return;

    const SCALE = 1.0; // reduce sensitivity for remote play
    
    // Accumulate deltas
    mouseMotionAccumulator.dx += e.movementX * SCALE;
    mouseMotionAccumulator.dy += e.movementY * SCALE;
    mouseMotionAccumulator.x = e.clientX;
    mouseMotionAccumulator.y = e.clientY;
    mouseMotionAccumulator.hasData = true;
});

document.addEventListener('mousedown', (e) => {
    if (document.pointerLockElement !== video) return;
    send({ type: 'mouse_button', button_index: e.button + 1, pressed: true, x: e.clientX, y: e.clientY });
});

document.addEventListener('mouseup', (e) => {
    if (document.pointerLockElement !== video) return;
    send({ type: 'mouse_button', button_index: e.button + 1, pressed: false, x: e.clientX, y: e.clientY });
});

document.addEventListener('wheel', (e) => {
    if (document.pointerLockElement !== video) return;
    send({ type: 'wheel', delta_y: e.deltaY, x: e.clientX, y: e.clientY });
});

// KEYBOARD (Desktop + Bluetooth Keyboards on Mobile)
// Note: On mobile, keydown events might only fire for input fields or have restrictions.
// We attach to 'window' to catch everything possible.
window.addEventListener('keydown', (e) => {
    // Allow keys if pointer locked OR if we are on touch device (implicit capture logic)
    // Checking for touch capability is tricky, but usually if pointerLockElement is null on desktop we ignore.
    // But on iPad with keyboard, pointerLock might not be active.
    
    // Send key regardless of lock status if it looks like a game key (WASD, etc)
    // or strictly enforce lock/touch active state.
    
    // Basic check: If pointer is locked OR we've touched recently (mobile mode)
    // Let's just ALWAYS send keys if the user has interacted with the page at least once?
    // Safer: Send keys if active.
    
    // On iPad, pointerLockElement will be null. We need a flag for "Mobile Input Active".
    send({ type: 'key', code: e.code, key: e.key, pressed: true });
});

window.addEventListener('keyup', (e) => {
    send({ type: 'key', code: e.code, key: e.key, pressed: false });
});

// TOUCH (Mobile / Tablet)
let lastTouchX = 0;
let lastTouchY = 0;

// Handle touch start - behaves like Mouse Down + Enable Capture
video.addEventListener('touchstart', (e) => {
    if (e.touches.length > 0) {
         const touch = e.touches[0];
         lastTouchX = touch.clientX;
         lastTouchY = touch.clientY;
         
         // Enable "captured" mode so camera_controller allows rotation
         send({ type: 'mouse_mode', captured: true });
         
         // Send click down (Left Mouse Button)
         send({ type: 'mouse_button', button_index: 1, pressed: true, x: touch.clientX, y: touch.clientY });
    }
}, { passive: false });

// Handle touch move - behaves like Mouse Move (Look)
video.addEventListener('touchmove', (e) => {
    // Prevent scrolling
    e.preventDefault();
    if (e.touches.length > 0) {
        const touch = e.touches[0];
        const dx = touch.clientX - lastTouchX;
        const dy = touch.clientY - lastTouchY;
        
        lastTouchX = touch.clientX;
        lastTouchY = touch.clientY;

        // Accumulate deltas
        mouseMotionAccumulator.dx += dx;
        mouseMotionAccumulator.dy += dy;
        mouseMotionAccumulator.x = touch.clientX;
        mouseMotionAccumulator.y = touch.clientY;
        mouseMotionAccumulator.hasData = true;
    }
}, { passive: false });

// Handle touch end - behaves like Mouse Up + Disable Capture
video.addEventListener('touchend', (e) => {
     // Release click
     send({ type: 'mouse_button', button_index: 1, pressed: false, x: 0, y: 0 });
     
     // Note: On a shooter game, you might NOT want to disable capture immediately 
     // if you want to keep using the keyboard? 
     // But for camera look, dragging stops here.
     // Let's disable capture to stop potential drifting.
     send({ type: 'mouse_mode', captured: false });
}, { passive: false });

