"""
Memex.AI Active Mode Daemon - Multi-threaded Background Service

ARCHITECTURE:
- Uses FastAPI endpoints from main.py (localhost:8000) for:
  * Face embedding extraction (/internal/extract-embedding)
  * Face matching with scoring (/internal/match-embedding)
- This keeps active_mode.py lightweight and uses a single shared model instance in main.py
- All heavy ML inference (InsightFace, face detection) happens in main.py
- active_mode.py acts as orchestrator: camera capture, medication scheduling

REQUIREMENTS (pip packages):
    pymongo
    opencv-python
    numpy
    pyttsx3
    apscheduler
    requests

Python 3.8+, runs on Raspberry Pi 3 (ARM64) with MongoDB on port 27017.
Requires main.py to be running on localhost:8000 before starting active_mode.py.
Two parallel threads: camera recognition, medication scheduler.
"""

import time
import threading
import logging
import os
from datetime import datetime
from typing import Dict, List, Optional
import json

import cv2
import numpy as np
import subprocess
import requests
import redis
from dotenv import load_dotenv
from pymongo import MongoClient
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

# Load environment variables
load_dotenv()

# Redis connection for TTS queue
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
REDIS_TTS_QUEUE = "memorymate:tts"
try:
    redis_client = redis.Redis.from_url(REDIS_URL, decode_responses=True)
    redis_client.ping()
except Exception as e:
    logging.warning(f"Redis not available — TTS will be silent: {e}")
    redis_client = None

# ============================================================================
# LOGGING SETUP
# ============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("active_mode.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("MemoryMate")

# ============================================================================
# CONFIGURATION
# ============================================================================

MONGO_URL = "mongodb://localhost:27017"
DB_NAME = "memorymate"
FASTAPI_URL = "http://localhost:8000"  # main.py endpoint for embeddings
FACE_RECOGNITION_COOLDOWN = 10  # seconds between announcements per person
CAMERA_RETRY_DELAY = 5  # seconds
FACE_SIMILARITY_THRESHOLD = .6  # Passed to API
MED_RELOAD_INTERVAL = 300  # seconds (5 minutes)



# ============================================================================
# GLOBAL STATE
# ============================================================================

# Thread-safe containers
last_announced_lock = threading.Lock()
last_announced: Dict[str, float] = {}  # {name: timestamp}
scheduled_meds_lock = threading.Lock()
scheduled_meds = set()  # {med_id}

# Shared models (loaded on startup)
scheduler: Optional[BackgroundScheduler] = None
mongo_client: Optional[MongoClient] = None
db = None

# Shutdown flag
shutdown_event = threading.Event()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================


def speak(text: str):
    """
    Push text to Redis TTS queue for the tts_worker.py to speak.
    Non-blocking — returns immediately so the camera loop isn't stalled.
    """
    try:
        logger.info(f"[SPEAK] {text}")
        if redis_client:
            redis_client.rpush(REDIS_TTS_QUEUE, text)
        else:
            # Direct espeak fallback if Redis is down
            subprocess.run(
                f'espeak -s 100 -a 100 --stdout "{text}" | aplay -B 100',
                shell=True,
                timeout=30,
                capture_output=True,
            )
    except Exception as e:
        logger.error(f"Error in speak(): {e}")



def extract_embedding_via_api(image_path: str) -> Optional[List[float]]:
    """
    Call main.py API to extract face embedding from image.
    Returns embedding vector or None if no face detected.
    """
    try:
        # Validate image_path is not empty
        if not image_path or not isinstance(image_path, str):
            logger.error(f"Invalid image_path: {image_path} (type: {type(image_path)})")
            return None

        # Prepare request payload
        payload = {"image_path": image_path}
        logger.debug(f"Sending embedding request with payload: {payload}")
        
        response = requests.post(
            f"{FASTAPI_URL}/internal/extract-embedding",
            json=payload,
            timeout=10,
        )
        if response.status_code == 200:
            data = response.json()
            return data.get("embedding")
        else:
            # Downgrade "no face" 400s to debug — they are expected when nobody is in frame
            if response.status_code == 400:
                logger.debug(
                    f"API: no face in frame (status {response.status_code})"
                )
            else:
                logger.error(
                    f"API error extracting embedding: {response.status_code} - "
                    f"Response: {response.text}"
                )
            return None
    except Exception as e:
        logger.error(f"Error calling extract-embedding API: {e}")
        return None


def match_embedding_via_api(embedding: List[float], threshold: float = 0.5) -> Optional[dict]:
    """
    Call main.py API to match embedding against enrolled faces.
    Returns match result {matched, name, relation, confidence} or None.
    """
    try:
        response = requests.post(
            f"{FASTAPI_URL}/internal/match-embedding",
            json={"embedding": embedding, "threshold": threshold},
            timeout=10,
        )
        if response.status_code == 200:
            return response.json()
        else:
            logger.error(f"API error matching embedding: {response.status_code}")
            return None
    except Exception as e:
        logger.error(f"Error calling match-embedding API: {e}")
        return None


# ============================================================================
# THREAD 1 — ALWAYS-ON CAMERA (FACE RECOGNITION)
# ============================================================================


def open_camera() -> Optional[cv2.VideoCapture]:
    """
    Open the camera with V4L2 backend and MJPEG codec.
    
    Why MJPEG: The default YUYV (uncompressed) format sends ~600MB/s of raw
    pixel data over USB. The Rubik Pi 3's USB controller can't keep up, causing
    V4L2 select() timeouts. MJPEG compresses frames in the camera hardware,
    reducing USB bandwidth by ~10x.
    """
    # Try V4L2 backend explicitly with /dev/video0
    for device in ["/dev/video0", "/dev/video1", 0]:
        try:
            if isinstance(device, str) and not os.path.exists(device):
                continue
            
            cam = cv2.VideoCapture(device, cv2.CAP_V4L2)
            if not cam.isOpened():
                cam.release()
                continue
            
            # Set MJPEG codec BEFORE resolution — order matters
            cam.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc('M', 'J', 'P', 'G'))
            cam.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cam.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            cam.set(cv2.CAP_PROP_FPS, 15)
            cam.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            
            # Verify it can actually read a frame
            ret, _ = cam.read()
            if ret:
                logger.info(f"[CAMERA] Opened {device} (MJPEG 640x480@15fps)")
                return cam
            else:
                logger.warning(f"[CAMERA] Opened {device} but couldn't read test frame")
                cam.release()
        except Exception as e:
            logger.debug(f"[CAMERA] Failed to open {device}: {e}")
    
    # Fallback: try default backend (no V4L2 explicit)
    try:
        cam = cv2.VideoCapture(0)
        if cam.isOpened():
            cam.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc('M', 'J', 'P', 'G'))
            cam.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cam.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            cam.set(cv2.CAP_PROP_FPS, 15)
            ret, _ = cam.read()
            if ret:
                logger.info("[CAMERA] Opened with default backend (MJPEG 640x480@15fps)")
                return cam
            cam.release()
    except Exception:
        pass
    
    return None


def thread_camera_loop():
    """
    Thread 1: Continuously capture frames from camera and recognize faces.
    Uses FastAPI endpoints to extract embeddings and match against enrolled faces.
    No local model — all ML inference happens in main.py.
    """
    logger.info("[THREAD 1] Camera face recognition loop starting...")
    
    camera = None
    frame_count = 0
    consecutive_failures = 0
    
    while not shutdown_event.is_set():
        try:
            # Open camera if not already open
            if camera is None:
                camera = open_camera()
                if camera is None:
                    consecutive_failures += 1
                    # Back off: wait longer after repeated failures
                    wait_time = min(CAMERA_RETRY_DELAY * consecutive_failures, 30)
                    logger.error(f"[CAMERA] Failed to open camera, retrying in {wait_time}s...")
                    time.sleep(wait_time)
                    continue
                consecutive_failures = 0
            
            # Capture frame
            ret, frame = camera.read()
            if not ret:
                logger.warning("[CAMERA] Failed to read frame, reopening camera...")
                camera.release()
                camera = None
                time.sleep(2)
                continue
            
            # Heartbeat log every 10 frames so we know the loop is alive
            if frame_count % 10 == 0:
                logger.info(f"[CAMERA] Frame {frame_count} captured ({frame.shape})")
            
            # Save frame temporarily for embedding extraction
            temp_frame_path = "/tmp/memorymate_frame.jpg"
            try:
                cv2.imwrite(temp_frame_path, frame)
                
                # Extract embedding via API (only called when local pre-check passes)
                embedding = extract_embedding_via_api(temp_frame_path)
                
                if embedding is not None:
                    # Match embedding against enrolled faces via API
                    match_result = match_embedding_via_api(
                        embedding,
                        threshold=FACE_SIMILARITY_THRESHOLD,
                    )
                    
                    if match_result and match_result.get("matched"):
                        name = match_result.get("name")
                        relation = match_result.get("relation", "")
                        confidence = match_result.get("confidence", 0)
                        
                        # Check cooldown
                        with last_announced_lock:
                            last_time = last_announced.get(name, 0)
                            current_time = time.time()
                            
                            if current_time - last_time > FACE_RECOGNITION_COOLDOWN:
                                # Announce
                                message = f"{name}, your {relation}, is in front of you"
                                logger.info(
                                    f"[RECOGNITION] {message} "
                                    f"(confidence: {confidence:.2f})"
                                )
                                speak(message)
                                last_announced[name] = current_time
            
            except Exception as e:
                logger.error(f"[CAMERA] Error processing frame: {e}")
            
            # Sleep for 1 second before next frame
            time.sleep(1)
            frame_count += 1
        
        except Exception as e:
            logger.error(f"[THREAD 1] Unexpected error: {e}")
            if camera:
                camera.release()
                camera = None
            time.sleep(CAMERA_RETRY_DELAY)
    
    # Cleanup
    if camera:
        camera.release()
    logger.info("[THREAD 1] Camera loop stopped")


# ============================================================================
# THREAD 2 — MEDICATION SCHEDULER
# ============================================================================


def medication_reminder_job(drug: str, dose: str, condition: str):
    """Callback function for medication reminder jobs."""
    message = f"{drug}, {dose}. Time to take your {condition} medicine."
    logger.info(f"[MEDICATION REMINDER] {message}")
    speak(message)


def reload_and_schedule_medications():
    """
    Load all medications from MongoDB and schedule APScheduler jobs.
    Only schedules new medications (skips already scheduled by ID).
    """
    global db, scheduler, scheduled_meds
    try:
        medications = db["medications"].find({})
        
        with scheduled_meds_lock:
            for med in medications:
                med_id = str(med["_id"])
                
                # Skip if already scheduled
                if med_id in scheduled_meds:
                    continue
                
                # Schedule each time in the times list
                for time_str in med.get("times", []):
                    try:
                        # Parse time (format: "HH:MM")
                        hour, minute = map(int, time_str.split(":"))
                        
                        # Create cron trigger for daily at this time
                        trigger = CronTrigger(hour=hour, minute=minute)
                        
                        job_id = f"{med_id}_{time_str}"
                        scheduler.add_job(
                            medication_reminder_job,
                            trigger=trigger,
                            args=(
                                med["drug"],
                                med["dose"],
                                med["condition"],
                            ),
                            id=job_id,
                            replace_existing=True,
                        )
                        
                        logger.info(
                            f"[MEDICATION] Scheduled: {med['drug']} ({med['dose']}) "
                            f"daily at {time_str}"
                        )
                    
                    except Exception as e:
                        logger.error(f"Error scheduling medication time {time_str}: {e}")
                
                scheduled_meds.add(med_id)
        
        logger.info(f"[MEDICATION] Total scheduled medications: {len(scheduled_meds)}")
    
    except Exception as e:
        logger.error(f"Error reloading medications: {e}")


def thread_medication_scheduler_loop():
    """
    Thread 2: Reload medications from MongoDB every 5 minutes.
    Uses APScheduler for the actual reminders.
    """
    logger.info("[THREAD 2] Medication scheduler loop starting...")
    
    last_reload = time.time()
    
    while not shutdown_event.is_set():
        try:
            current_time = time.time()
            if current_time - last_reload > MED_RELOAD_INTERVAL:
                reload_and_schedule_medications()
                last_reload = current_time
            
            time.sleep(10)  # Check every 10 seconds if reload is needed
        
        except Exception as e:
            logger.error(f"[THREAD 2] Unexpected error: {e}")
            time.sleep(10)
    
    logger.info("[THREAD 2] Medication scheduler loop stopped")


# ============================================================================
# STARTUP SEQUENCE
# ============================================================================


def startup():
    """Initialize all models and connections in order."""
    global scheduler, mongo_client, db
    
    try:
        # 1. Verify FastAPI server is running
        logger.info("[STARTUP] 1/3 Checking FastAPI server connection...")
        try:
            response = requests.get(f"{FASTAPI_URL}/health", timeout=5)
            if response.status_code == 200:
                logger.info("[STARTUP] ✓ FastAPI server is running (embedding service available)")
            else:
                raise RuntimeError("FastAPI server not responding correctly")
        except Exception as e:
            logger.error(f"[STARTUP] FastAPI server not reachable at {FASTAPI_URL}")
            logger.error(f"[STARTUP] Make sure main.py is running: python3 main.py")
            raise
        
        # 2. Connect to MongoDB
        logger.info("[STARTUP] 2/3 Connecting to MongoDB...")
        mongo_client = MongoClient(MONGO_URL)
        db = mongo_client[DB_NAME]
        db.command("ping")
        logger.info("[STARTUP] ✓ MongoDB connected")
        
        # 3. Start APScheduler
        logger.info("[STARTUP] 3/3 Starting APScheduler...")
        scheduler = BackgroundScheduler()
        scheduler.start()
        logger.info("[STARTUP] ✓ APScheduler started")
        
        # Load medications and schedule jobs
        logger.info("[STARTUP] Loading and scheduling medications...")
        reload_and_schedule_medications()
        
        logger.info("[STARTUP] ✓ All systems initialized!")
        speak("MemoryMate is ready.")
        
        return True
    
    except Exception as e:
        logger.error(f"[STARTUP] Fatal error during initialization: {e}")
        return False


# ============================================================================
# MAIN
# ============================================================================


def main():
    """Main entry point — start all threads and keep process alive."""
    logger.info("=" * 60)
    logger.info("MemoryMate Active Mode Daemon Starting")
    logger.info("=" * 60)
    
    # Startup
    if not startup():
        logger.error("Startup failed, exiting")
        return
    
    # Start Thread 1 (Camera)
    logger.info("Starting Thread 1 (Camera face recognition)...")
    t1 = threading.Thread(target=thread_camera_loop, daemon=True)
    t1.start()
    
    # Start Thread 2 (Medication Scheduler)
    logger.info("Starting Thread 2 (Medication scheduler)...")
    t2 = threading.Thread(target=thread_medication_scheduler_loop, daemon=True)
    t2.start()
    
    logger.info("All threads started. MemoryMate is running...")
    logger.info("Press Ctrl+C to stop.")
    
    try:
        # Keep main thread alive
        while not shutdown_event.is_set():
            time.sleep(1)
    
    except KeyboardInterrupt:
        logger.info("Received interrupt signal, shutting down...")
        shutdown_event.set()
        time.sleep(2)  # Give threads time to exit
        
        if scheduler:
            scheduler.shutdown()
        if mongo_client:
            mongo_client.close()
        
        logger.info("MemoryMate Active Mode stopped.")


if __name__ == "__main__":
    main()
