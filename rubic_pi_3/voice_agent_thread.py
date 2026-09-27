"""
MemoryMate local voice agent.

Audio is recorded through sounddevice, transcribed locally with Whisper, sent
to the MCP agent, and queued in Redis for local text-to-speech playback.
"""

import asyncio
import json
import logging
import os
import threading
import time
from typing import Optional

import numpy as np
import redis
import scipy.io.wavfile as wavfile
import sounddevice as sd

import config
from mcp_agent_client import execute_agent_with_tools


logging.basicConfig(
    level=config.LOG_LEVEL,
    format=config.LOG_FORMAT,
    handlers=[
        logging.FileHandler("voice_agent.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("VoiceAgent")

try:
    redis_client = redis.Redis.from_url(config.REDIS_URL, decode_responses=True)
    redis_client.ping()
    logger.info("Connected to Redis")
except Exception as exc:
    logger.warning("Redis not available: %s", exc)
    redis_client = None

_whisper_model = None
_whisper_lock = threading.Lock()


def _get_whisper_model():
    """Load the local Whisper model once and reuse it for every recording."""
    global _whisper_model
    if _whisper_model is None:
        with _whisper_lock:
            if _whisper_model is None:
                import whisper

                logger.info("Loading local Whisper model: %s", config.WHISPER_MODEL)
                _whisper_model = whisper.load_model(config.WHISPER_MODEL)
    return _whisper_model


def detect_wake_word_energy(audio_chunk: np.ndarray) -> bool:
    """Return True when the audio energy is high enough to contain speech."""
    if len(audio_chunk) == 0:
        return False
    rms = float(np.sqrt(np.mean(audio_chunk**2)))
    return rms > config.SPEECH_ENERGY_THRESHOLD


def detect_wake_word_from_text(transcribed_text: str) -> bool:
    """Check a transcription for the configured wake phrase."""
    if not transcribed_text:
        return False
    found = config.WAKE_WORD.lower() in transcribed_text.lower().strip()
    if found:
        logger.info(
            "Wake word '%s' detected in: %s",
            config.WAKE_WORD,
            transcribed_text,
        )
    return found


def record_audio(
    duration: float,
    sample_rate: int = config.MIC_SAMPLE_RATE,
) -> Optional[np.ndarray]:
    """Record one mono audio clip from the default input device."""
    try:
        audio_data = sd.rec(
            int(duration * sample_rate),
            samplerate=sample_rate,
            channels=config.MIC_CHANNELS,
            dtype=np.float32,
        )
        sd.wait()
        return audio_data[:, 0] if audio_data.ndim > 1 else audio_data
    except Exception:
        logger.exception("Error recording audio")
        return None


def convert_speech_to_text(
    audio_file_path: str,
    initial_prompt: Optional[str] = None,
) -> Optional[str]:
    """Transcribe a WAV file locally with Whisper."""
    try:
        model = _get_whisper_model()
        result = model.transcribe(
            audio_file_path,
            language="en",
            fp16=False,
            condition_on_previous_text=False,
            temperature=0,
            initial_prompt=initial_prompt,
        )
        text = result.get("text", "").strip()
        if text:
            logger.info("Transcribed: %s", text)
            return text
        logger.info("Whisper returned no text")
        return None
    except ImportError:
        logger.exception("Whisper is not installed")
        return None
    except Exception:
        logger.exception("Local Whisper transcription failed")
        return None


def listen_for_wake_word(chunk_duration: float = 1.5) -> bool:
    """Listen for one audio chunk and detect the configured wake phrase."""
    audio_chunk = record_audio(chunk_duration)
    if audio_chunk is None or len(audio_chunk) == 0:
        return False
    if not detect_wake_word_energy(audio_chunk):
        return False

    temp_audio_path = f"/tmp/memorymate_wakeword_{time.time_ns()}.wav"
    try:
        wavfile.write(
            temp_audio_path,
            config.MIC_SAMPLE_RATE,
            (audio_chunk * 32767).astype(np.int16),
        )
        text = convert_speech_to_text(
            temp_audio_path,
            initial_prompt=f"The wake phrase is {config.WAKE_WORD}.",
        )
        return detect_wake_word_from_text(text or "")
    finally:
        try:
            os.remove(temp_audio_path)
        except OSError:
            pass


def enqueue_tts_response(response_text: str) -> bool:
    """Queue text for the local TTS worker."""
    if not redis_client:
        logger.warning("Redis not available, cannot enqueue TTS")
        return False
    try:
        redis_client.rpush(config.REDIS_TTS_QUEUE, json.dumps(response_text))
        logger.info("Enqueued to TTS: %s", response_text[:80])
        return True
    except Exception:
        logger.exception("Error enqueueing TTS")
        return False


async def voice_agent_loop(shutdown_event: threading.Event) -> None:
    """Run the wake word, transcription, agent, and TTS loop."""
    logger.info("Voice agent started with fully local speech processing")
    logger.info("Listening for wake word: '%s'", config.WAKE_WORD)

    try:
        _get_whisper_model()
    except Exception:
        logger.exception("Unable to initialize local Whisper")
        return

    while not shutdown_event.is_set():
        try:
            if not listen_for_wake_word(config.WAKE_WORD_CHUNK_DURATION):
                time.sleep(0.2)
                continue

            enqueue_tts_response("How can I help you?")
            time.sleep(0.5)
            user_audio = record_audio(config.SPEECH_RECORD_DURATION)
            if user_audio is None or len(user_audio) == 0:
                continue

            temp_audio_path = f"/tmp/memorymate_voice_{time.time_ns()}.wav"
            try:
                wavfile.write(
                    temp_audio_path,
                    config.MIC_SAMPLE_RATE,
                    (user_audio * 32767).astype(np.int16),
                )
                user_text = convert_speech_to_text(temp_audio_path)
            finally:
                try:
                    os.remove(temp_audio_path)
                except OSError:
                    pass

            if not user_text:
                enqueue_tts_response("Sorry, I did not catch that. Please repeat.")
                continue

            logger.info("Processing user request: %s", user_text)
            agent_response = await execute_agent_with_tools(user_text)
            if agent_response:
                enqueue_tts_response(agent_response)
            else:
                enqueue_tts_response("Sorry, I could not process that request.")
        except Exception:
            logger.exception("Error in voice agent loop")
            time.sleep(1)

    logger.info("Voice agent stopped")


def start_voice_agent_thread(shutdown_event: threading.Event) -> threading.Thread:
    """Start the voice agent in a daemon thread."""

    def run() -> None:
        asyncio.run(voice_agent_loop(shutdown_event))

    thread = threading.Thread(target=run, daemon=True, name="VoiceAgent")
    thread.start()
    return thread


if __name__ == "__main__":
    event = threading.Event()
    try:
        asyncio.run(voice_agent_loop(event))
    except KeyboardInterrupt:
        event.set()
