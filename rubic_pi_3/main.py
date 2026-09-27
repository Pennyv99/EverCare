import os
import shutil
import subprocess
import base64
import asyncio
import io
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import List, Optional

import cv2
import insightface
import numpy as np
import sounddevice as sd
from bson import ObjectId
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from motor.motor_asyncio import AsyncIOMotorClient
from pydantic import BaseModel, ConfigDict, Field

# Import shared helpers
from face_helpers import compute_embedding_similarity, match_face_embedding
from mcp_agent_client import execute_agent_with_tools
import config

# ============================================================================
# CONFIGURATION
# ============================================================================

DATA_DIR = Path("./data/faces")
MONGO_URL = "mongodb://localhost:27017"
DB_NAME = "memorymate"

# ============================================================================
# PYDANTIC MODELS
# ============================================================================


class EnrollFaceResponse(BaseModel):
    status: str
    id: str
    name: str
    relation: str


class MedicationRequest(BaseModel):
    drug: str
    dose: str
    times: List[str]
    condition: str


class MedicationResponse(BaseModel):
    id: str = Field(alias="_id")
    drug: str
    dose: str
    times: List[str]
    condition: str
    created_at: datetime

    model_config = ConfigDict(populate_by_name=True)


class FaceResponse(BaseModel):
    id: str  # No alias - we'll convert manually
    name: str
    relation: str
    image_paths: List[str]
    image_data: List[str]  # Base64 encoded images for UI display
    embeddings: List[List[float]]  # Stores face embeddings from multiple images
    enrolled_at: datetime

    model_config = ConfigDict(populate_by_name=True)


class FaceMatchResult(BaseModel):
    matched: bool
    name: str
    relation: Optional[str] = None
    confidence: float  # Similarity score 0-1 (1 = perfect match)


class RecognitionRequest(BaseModel):
    image: UploadFile = File(...)


class StatusResponse(BaseModel):
    status: str


class HealthResponse(BaseModel):
    status: str
    camera: bool
    mic: bool
    speaker: bool


class ErrorResponse(BaseModel):
    error: str


class AgentRequest(BaseModel):
    """Request model for agent endpoint"""
    query: str  # User's question/command (e.g., "What reminders do I have?")
    timeout: Optional[int] = 30  # Optional timeout in seconds


class AgentResponse(BaseModel):
    """Response model for agent endpoint"""
    query: str  # Echo back the query
    response: str  # Agent's response
    status: str = "success"  # success, timeout, error
    error: Optional[str] = None  # Error message if status is error


# ============================================================================
# GLOBAL STATE
# ============================================================================

mongo_client: Optional[AsyncIOMotorClient] = None
db = None
face_model: Optional[insightface.app.FaceAnalysis] = None
model_initialized = False


def initialize_face_model():
    """Initialize InsightFace model for face detection and embedding generation."""
    global face_model, model_initialized
    try:
        print("[FACE_MODEL] Initializing InsightFace model (buffalo_l)...")
        face_model = insightface.app.FaceAnalysis(
            name="buffalo_l",
            providers=["CPUProvider"]
        )
        face_model.prepare(ctx_id=0, det_thresh=0.5, det_size=(640, 640))
        model_initialized = True
        print("[FACE_MODEL] ✓ InsightFace model loaded successfully")
    except Exception as e:
        print(f"[FACE_MODEL] ✗ Failed to initialize InsightFace model: {e}")
        model_initialized = False


def extract_face_embedding(image_path: str) -> Optional[np.ndarray]:
    """
    Extract face embedding from an image file.
    Returns the embedding vector (512-dim) or None if no face detected.
    """
    global face_model

    if face_model is None or not model_initialized:
        raise RuntimeError("Face model not initialized")

    try:
        img = cv2.imread(str(image_path))
        if img is None:
            print(f"[FACE_MODEL] Warning: Could not read image {image_path}")
            return None

        # Detect faces and extract embeddings
        faces = face_model.get(img)
        if len(faces) == 0:
            print(f"[FACE_MODEL] Warning: No face detected in {image_path}")
            return None

        # Use the first (largest) detected face
        embedding = faces[0].embedding
        normalized = embedding / np.linalg.norm(embedding)  # L2 normalize
        return normalized

    except Exception as e:
        print(f"[FACE_MODEL] Error extracting embedding from {image_path}: {e}")
        return None


def generate_multiple_embeddings(image_paths: List[str]) -> List[List[float]]:
    """
    Generate embeddings for multiple images.
    Returns list of normalized embedding vectors (as lists for JSON serialization).
    """
    embeddings = []
    for path in image_paths:
        embedding = extract_face_embedding(path)
        if embedding is not None:
            embeddings.append(embedding.tolist())

    return embeddings


def read_images_as_base64(image_paths: List[str]) -> List[str]:
    """
    Read images from disk and convert to base64 for JSON response.
    Returns list of base64 encoded image strings.
    """
    image_data = []
    for path in image_paths:
        try:
            with open(path, "rb") as f:
                img_bytes = f.read()
                b64_str = base64.b64encode(img_bytes).decode("utf-8")
                image_data.append(b64_str)
        except Exception as e:
            print(f"Error reading image {path}: {e}")
            image_data.append("")  # Empty string on error

    return image_data


# ============================================================================
# LIFESPAN CONTEXT MANAGER
# ============================================================================


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown logic for MongoDB and resources."""
    global mongo_client, db

    # Startup
    print("Starting up MemoryMate FastAPI server...")

    # Create data directory if it doesn't exist
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Ensured data directory exists: {DATA_DIR}")

    # Initialize face model for embeddings
    initialize_face_model()

    # Initialize MongoDB client
    mongo_client = AsyncIOMotorClient(MONGO_URL)
    db = mongo_client[DB_NAME]
    print("Connected to MongoDB")

    yield

    # Shutdown
    print("Shutting down MemoryMate FastAPI server...")
    if mongo_client:
        mongo_client.close()
        print("Closed MongoDB connection")


# ============================================================================
# APP INITIALIZATION
# ============================================================================

app = FastAPI(
    title="MemoryMate Backend",
    description="Medical assistive device backend for caregiver iOS app",
    version="1.0.0",
    lifespan=lifespan,
)

# Add CORS middleware (allow all origins for Tailscale network)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ============================================================================
# EXCEPTION HANDLER
# ============================================================================


@app.exception_handler(Exception)
async def global_exception_handler(request, exc):
    """Top-level exception handler."""
    print(f"Unhandled exception: {exc}")
    return {
        "error": str(exc),
    }, 500


# ============================================================================
# HEALTH CHECK ENDPOINT
# ============================================================================


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """
    Check health of connected hardware (camera, mic, speaker).
    NOTE: Camera check uses device-file existence instead of cv2.VideoCapture()
    to avoid stealing /dev/video0 from active_mode.py's camera thread.
    """
    # Check camera — non-invasive check (don't open the device!)
    # Opening cv2.VideoCapture(0) here would grab exclusive access on Linux
    # and cause active_mode.py's camera thread to lose the device.
    camera_ok = False
    try:
        camera_ok = os.path.exists("/dev/video0") or os.path.exists("/dev/video1")
    except Exception as e:
        print(f"Camera check failed: {e}")

    # Check microphone
    mic_ok = False
    try:
        devices = sd.query_devices()
        mic_ok = any(d["max_input_channels"] > 0 for d in devices)
    except Exception as e:
        print(f"Microphone check failed: {e}")

    # Check speaker
    speaker_ok = False
    try:
        # Check if /dev/snd exists and query playback devices
        if os.path.exists("/dev/snd"):
            result = subprocess.run(
                ["aplay", "-l"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            speaker_ok = result.returncode == 0 and len(result.stdout) > 0
    except Exception as e:
        print(f"Speaker check failed: {e}")

    return HealthResponse(
        status="ok",
        camera=camera_ok,
        mic=mic_ok,
        speaker=speaker_ok,
    )


# ============================================================================
# FACE ENROLLMENT ENDPOINTS
# ============================================================================


@app.post("/enroll-face", response_model=EnrollFaceResponse)
async def enroll_face(
    name: str = Form(...),
    relation: str = Form(...),
    files: List[UploadFile] = File(...),
):
    """
    Enroll a person by name, relation, and face images.
    Generates and stores face embeddings for recognition.
    Requires face_service.py to be running for embedding extraction.
    """

    # Create directory for this person
    person_dir = DATA_DIR / name
    person_dir.mkdir(parents=True, exist_ok=True)

    image_paths = []
    try:
        for idx, file in enumerate(files):
            # Validate file is JPEG
            if file.content_type not in ["image/jpeg", "image/jpg"]:
                raise HTTPException(
                    status_code=400,
                    detail=f"File {file.filename} is not JPEG format",
                )

            # Save file
            file_path = person_dir / f"{name}_{idx}.jpg"
            contents = await file.read()
            with open(file_path, "wb") as f:
                f.write(contents)

            image_paths.append(str(file_path))

    except HTTPException:
        raise
    except Exception as e:
        # Clean up on error
        if person_dir.exists():
            shutil.rmtree(person_dir)
        raise HTTPException(
            status_code=500,
            detail=f"Error saving images: {str(e)}",
        )

    # Generate face embeddings from saved images
    embeddings = []
    try:
        embeddings = generate_multiple_embeddings(image_paths)
    except HTTPException:
        if person_dir.exists():
            shutil.rmtree(person_dir)
        raise
    except Exception as e:
        if person_dir.exists():
            shutil.rmtree(person_dir)
        raise HTTPException(
            status_code=500,
            detail=f"Error extracting face embeddings: {str(e)}",
        )

    if not embeddings:
        # Clean up on error
        if person_dir.exists():
            shutil.rmtree(person_dir)
        raise HTTPException(
            status_code=400,
            detail="Could not extract face embeddings from images. Ensure images contain clear faces.",
        )

    # Store in MongoDB
    face_doc = {
        "name": name,
        "relation": relation,
        "image_paths": image_paths,
        "embeddings": embeddings,  # Store normalized embedding vectors
        "enrolled_at": datetime.utcnow(),
    }

    try:
        result = await db["faces"].insert_one(face_doc)
        return EnrollFaceResponse(
            status="enrolled",
            id=str(result.inserted_id),
            name=name,
            relation=relation,
        )
    except Exception as e:
        # Clean up on error
        if person_dir.exists():
            shutil.rmtree(person_dir)
        raise HTTPException(
            status_code=500,
            detail=f"Error storing face document: {str(e)}",
        )


@app.get("/enrolled-faces", response_model=List[FaceResponse])
async def get_enrolled_faces():
    """
    Retrieve all enrolled faces with image data (base64 encoded).
    """
    try:
        faces = await db["faces"].find({}).to_list(None)
        result = []
        for face in faces:
            # Convert ObjectId to string
            face_data = {
                "id": str(face["_id"]),
                "name": face["name"],
                "relation": face["relation"],
                "image_paths": face["image_paths"],
                "embeddings": face["embeddings"],
                "enrolled_at": face["enrolled_at"],
                "image_data": read_images_as_base64(face["image_paths"]),
            }
            result.append(FaceResponse(**face_data))
        return result
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error retrieving faces: {str(e)}",
        )


@app.delete("/face/{face_id}", response_model=StatusResponse)
async def delete_face(face_id: str):
    """
    Delete a face document and its associated images.
    """
    try:
        # Validate ObjectId
        obj_id = ObjectId(face_id)
    except Exception:
        raise HTTPException(
            status_code=400,
            detail="Invalid face ID format",
        )

    try:
        # Retrieve document first to get image paths and name
        face_doc = await db["faces"].find_one({"_id": obj_id})
        if not face_doc:
            raise HTTPException(
                status_code=404,
                detail="Face not found",
            )

        # Delete directory with images
        person_dir = DATA_DIR / face_doc["name"]
        if person_dir.exists():
            shutil.rmtree(person_dir)

        # Delete from database
        await db["faces"].delete_one({"_id": obj_id})

        return StatusResponse(status="deleted")

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error deleting face: {str(e)}",
        )


@app.post("/recognize-face", response_model=FaceMatchResult)
async def recognize_face(file: UploadFile = File(...)):
    """
    Recognize a person from an image by matching face embeddings.
    Returns the best matching enrolled face with confidence score.
    Requires face_service.py to be running for embedding extraction.
    """
    try:
        # Save uploaded file temporarily
        temp_path = Path("/tmp") / f"temp_face_{datetime.utcnow().timestamp()}.jpg"
        contents = await file.read()
        with open(temp_path, "wb") as f:
            f.write(contents)

        # Extract embedding from uploaded image
        query_embedding = extract_face_embedding(str(temp_path))
        if query_embedding is None:
            temp_path.unlink(missing_ok=True)
            raise HTTPException(
                status_code=400,
                detail="No face detected in uploaded image",
            )

        # Match against enrolled faces
        match_result = await match_face_embedding(query_embedding.tolist(), db, threshold=0.6)

        # Clean up temp file
        temp_path.unlink(missing_ok=True)

        if match_result:
            face_doc = match_result["document"]
            return FaceMatchResult(
                matched=True,
                name=face_doc["name"],
                relation=face_doc.get("relation"),
                confidence=match_result["confidence"],
            )
        else:
            return FaceMatchResult(
                matched=False,
                name="Unknown",
                relation=None,
                confidence=0.0,
            )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error during face recognition: {str(e)}",
        )


# ============================================================================
# MEDICATION ENDPOINTS
# ============================================================================


@app.post("/add-medication", response_model=dict)
async def add_medication(med: MedicationRequest):
    """
    Add a medication to the schedule.
    """
    med_doc = {
        "drug": med.drug,
        "dose": med.dose,
        "times": med.times,
        "condition": med.condition,
        "created_at": datetime.utcnow(),
    }

    try:
        result = await db["medications"].insert_one(med_doc)
        return {
            "status": "saved",
            "id": str(result.inserted_id),
        }
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error saving medication: {str(e)}",
        )


@app.get("/medications", response_model=List[MedicationResponse])
async def get_medications():
    """
    Retrieve all medications from the schedule.
    """
    try:
        medications = await db["medications"].find({}).to_list(None)
        for med in medications:
            if "_id" in med:
                med["_id"] = str(med["_id"])
        return [MedicationResponse(**med) for med in medications]
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error retrieving medications: {str(e)}",
        )


@app.delete("/medication/{med_id}", response_model=StatusResponse)
async def delete_medication(med_id: str):
    """
    Delete a medication entry by ID.
    """
    try:
        # Validate ObjectId
        obj_id = ObjectId(med_id)
    except Exception:
        raise HTTPException(
            status_code=400,
            detail="Invalid medication ID format",
        )

    try:
        result = await db["medications"].delete_one({"_id": obj_id})
        if result.deleted_count == 0:
            raise HTTPException(
                status_code=404,
                detail="Medication not found",
            )

        return StatusResponse(status="deleted")

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error deleting medication: {str(e)}",
        )


# ============================================================================
# REMINDER ENDPOINTS
# ============================================================================


class ReminderResponse(BaseModel):
    """Response model for a single reminder"""
    id: str = Field(alias="_id")
    title: str
    time: str
    status: str
    created_at: datetime

    model_config = ConfigDict(populate_by_name=True)


@app.get("/reminders", response_model=List[ReminderResponse])
async def get_all_reminders():
    """
    Retrieve all active reminders sorted by time.
    """
    try:
        reminders = await db["reminders"].find({"status": "active"}).sort("time", 1).to_list(None)
        for rem in reminders:
            if "_id" in rem:
                rem["_id"] = str(rem["_id"])
        return [ReminderResponse(**rem) for rem in reminders]
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error retrieving reminders: {str(e)}",
        )


@app.delete("/reminders/reset", response_model=dict)
async def reset_all_reminders():
    """
    Delete all reminders from the database (reset).
    """
    try:
        result = await db["reminders"].delete_many({})
        return {
            "status": "reset",
            "deleted_count": result.deleted_count,
            "message": f"Deleted {result.deleted_count} reminder(s)",
        }
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error resetting reminders: {str(e)}",
        )


# ============================================================================
# INTERNAL API ENDPOINTS (For other services/scripts to call)
# ============================================================================


class EmbeddingRequest(BaseModel):
    image_path: str = Field(..., min_length=1, description="Path to image file")


class EmbeddingResponse(BaseModel):
    embedding: List[float]


@app.post("/internal/extract-embedding", response_model=EmbeddingResponse)
async def internal_extract_embedding(req: EmbeddingRequest):
    """
    Internal endpoint: Extract face embedding from an image.
    Other scripts/services can call this instead of importing face functions.
    
    Expects JSON body: {"image_path": "/path/to/image.jpg"}
    """
    try:
        # Validate image_path exists
        if not os.path.exists(req.image_path):
            raise HTTPException(
                status_code=400,
                detail=f"Image file not found: {req.image_path}",
            )
        
        embedding = extract_face_embedding(req.image_path)
        if embedding is None:
            raise HTTPException(
                status_code=400,
                detail="No face detected in image",
            )
        return EmbeddingResponse(embedding=embedding.tolist())
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error extracting embedding: {str(e)}",
        )


class EmbeddingMatchRequest(BaseModel):
    embedding: List[float]
    threshold: float = 0.6


@app.post("/internal/match-embedding", response_model=FaceMatchResult)
async def internal_match_embedding(req: EmbeddingMatchRequest):
    """
    Internal endpoint: Match an embedding against enrolled faces.
    Other scripts/services can call this instead of importing face functions.
    """
    try:
        match_result = await match_face_embedding(req.embedding, db, threshold=req.threshold)
        if match_result:
            face_doc = match_result["document"]
            return FaceMatchResult(
                matched=True,
                name=face_doc["name"],
                relation=face_doc.get("relation"),
                confidence=match_result["confidence"],
            )
        else:
            return FaceMatchResult(
                matched=False,
                name="Unknown",
                relation=None,
                confidence=0.0,
            )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error matching embedding: {str(e)}",
        )


# ============================================================================
# AGENT API ENDPOINT
# ============================================================================


@app.post("/agent", response_model=AgentResponse)
async def agent_endpoint(req: AgentRequest):
    """
    Agent API endpoint: Process user queries through the MCP agent.
    
    This endpoint receives text queries and returns responses from the agent,
    which has access to tools like:
    - set_reminder(title, time_str)
    - get_all_reminders()
    - get_latest_reminders(count)
    - get_latest_medication()
    
    Example queries:
    - "What reminders do I have?"
    - "Set a reminder to take medication at 9 AM"
    - "What's my next medication?"
    
    Args:
        req: AgentRequest containing the user's query
        
    Returns:
        AgentResponse with the agent's response
    """
    try:
        print(f"[AGENT] Processing query: {req.query}")
        
        # Execute agent with optional timeout
        try:
            if req.timeout:
                response = await asyncio.wait_for(
                    execute_agent_with_tools(req.query),
                    timeout=req.timeout
                )
            else:
                response = await execute_agent_with_tools(req.query)
            
            if response is None:
                return AgentResponse(
                    query=req.query,
                    response="Agent returned no response",
                    status="error",
                    error="Agent failed to process query"
                )
            
            print(f"[AGENT] Response: {response}")
            return AgentResponse(
                query=req.query,
                response=response,
                status="success"
            )
            
        except asyncio.TimeoutError:
            print(f"[AGENT] Query timed out after {req.timeout}s")
            return AgentResponse(
                query=req.query,
                response="",
                status="timeout",
                error=f"Agent processing timed out after {req.timeout} seconds"
            )
        except Exception as e:
            print(f"[AGENT] Error: {e}")
            return AgentResponse(
                query=req.query,
                response="",
                status="error",
                error=str(e)
            )
            
    except Exception as e:
        print(f"[AGENT] Unexpected error: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Error processing agent request: {str(e)}"
        )


# ============================================================================
# AGENT VOICE ENDPOINT
# ============================================================================


@app.post("/agent-voice")
async def agent_voice_endpoint(req: AgentRequest):
    """
    Agent Voice API endpoint: Process queries and return audio response.
    
    Combines the agent endpoint with text-to-speech to return an audio file
    that can be played directly on iOS or other clients.
    
    Args:
        req: AgentRequest containing the user's query
        
    Returns:
        Audio file (MP3) as a streaming response
        
    Example:
        POST /agent-voice
        {"query": "What reminders do I have?"}
        
        Response: Audio file (MP3) with agent's response read aloud
    """
    try:
        print(f"[AGENT-VOICE] Processing query: {req.query}")
        
        # Step 1: Get text response from agent
        try:
            if req.timeout:
                response_text = await asyncio.wait_for(
                    execute_agent_with_tools(req.query),
                    timeout=req.timeout
                )
            else:
                response_text = await execute_agent_with_tools(req.query)
            
            if response_text is None:
                response_text = "I couldn't process your request."
            
            print(f"[AGENT-VOICE] Agent response: {response_text}")
            
        except asyncio.TimeoutError:
            response_text = f"Agent processing timed out after {req.timeout} seconds. Please try again."
            print(f"[AGENT-VOICE] Timeout: {response_text}")
        except Exception as e:
            response_text = f"Error processing your request: {str(e)}"
            print(f"[AGENT-VOICE] Error: {response_text}")
        
        # Step 2: Convert text to speech
        print(f"[AGENT-VOICE] Converting to speech: {response_text[:100]}...")
        audio_bytes = await text_to_speech_audio(response_text)
        
        if audio_bytes is None:
            print("[AGENT-VOICE] ✗ Failed to generate audio")
            raise HTTPException(
                status_code=500,
                detail="Failed to convert response to speech"
            )
        
        print(f"[AGENT-VOICE] ✓ Generated {len(audio_bytes)} bytes of audio")
        
        # Step 3: Return audio as streaming response
        audio_stream = io.BytesIO(audio_bytes)
        return StreamingResponse(
            iter([audio_bytes]),
            media_type="audio/mpeg",
            headers={
                "Content-Disposition": "inline; filename=agent_response.mp3",
                "Cache-Control": "no-cache, no-store, must-revalidate"
            }
        )
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"[AGENT-VOICE] Unexpected error: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Error processing agent voice request: {str(e)}"
        )


# ============================================================================
# RESET ENDPOINT (FOR TESTING)
# ============================================================================


@app.delete("/reset")
async def reset_all():
    """
    Reset entire system: delete all data from MongoDB and disk.
    WARNING: This is destructive and should only be used during testing!
    Deletes:
    - All documents from 'faces' collection
    - All documents from 'medications' collection
    - All face images from ./data/faces/ directory
    """
    try:
        # Delete all faces from database
        faces_result = await db["faces"].delete_many({})
        print(f"[RESET] Deleted {faces_result.deleted_count} face documents")

        # Delete all medications from database
        meds_result = await db["medications"].delete_many({})
        print(f"[RESET] Deleted {meds_result.deleted_count} medication documents")

        # Delete face images directory
        if DATA_DIR.exists():
            shutil.rmtree(DATA_DIR)
            print(f"[RESET] Deleted directory: {DATA_DIR}")

        # Recreate empty faces directory
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        print(f"[RESET] Recreated empty directory: {DATA_DIR}")

        return {
            "status": "reset",
            "faces_deleted": faces_result.deleted_count,
            "medications_deleted": meds_result.deleted_count,
            "message": "All data cleared successfully",
        }

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error during reset: {str(e)}",
        )


# ============================================================================
# ENTRY POINT
# ============================================================================

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
