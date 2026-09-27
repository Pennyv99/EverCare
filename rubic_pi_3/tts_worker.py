"""MemoryMate local neural text-to-speech worker using Piper."""

import logging
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave

from piper import PiperVoice
import redis
from dotenv import load_dotenv


load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] [TTS] %(message)s",
    handlers=[
        logging.FileHandler("tts_worker.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("TTS_Worker")

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
REDIS_QUEUE = "memorymate:tts"
PROJECT_DIR = Path(__file__).resolve().parent
PIPER_MODEL_PATH = Path(
    os.getenv("PIPER_MODEL_PATH", "data/voices/en_US-lessac-medium.onnx")
)
if not PIPER_MODEL_PATH.is_absolute():
    PIPER_MODEL_PATH = PROJECT_DIR / PIPER_MODEL_PATH
PIPER_CONFIG_PATH = Path(f"{PIPER_MODEL_PATH}.json")


try:
    redis_client = redis.Redis.from_url(REDIS_URL, decode_responses=True)
    redis_client.ping()
    logger.info("Connected to Redis at %s", REDIS_URL)
except Exception as exc:
    logger.error("Cannot connect to Redis: %s", exc)
    logger.error("Make sure Redis is running: sudo systemctl start redis-server")
    sys.exit(1)

if not PIPER_MODEL_PATH.is_file() or not PIPER_CONFIG_PATH.is_file():
    logger.error("Piper voice model is missing: %s", PIPER_MODEL_PATH)
    logger.error(
        "Download it with: python -m piper.download_voices "
        "--data-dir data/voices en_US-lessac-medium"
    )
    sys.exit(1)

try:
    piper_voice = PiperVoice.load(
        PIPER_MODEL_PATH,
        config_path=PIPER_CONFIG_PATH,
    )
    logger.info("Loaded Piper voice: %s", PIPER_MODEL_PATH.name)
except Exception:
    logger.exception("Unable to load the Piper voice model")
    sys.exit(1)


def speak(text: str) -> None:
    """Generate neural speech locally and play it through the wired sink."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as audio_file:
        audio_path = Path(audio_file.name)

    try:
        with wave.open(str(audio_path), "wb") as wav_file:
            piper_voice.synthesize_wav(text, wav_file)

        if shutil.which("pw-play"):
            playback_command = ["pw-play", str(audio_path)]
        else:
            playback_command = [
                "aplay",
                "-q",
                "--buffer-time=500000",
                "--period-time=100000",
                str(audio_path),
            ]

        playback = subprocess.run(
            playback_command,
            capture_output=True,
            timeout=60,
            check=False,
        )
        if playback.returncode != 0:
            raise RuntimeError(
                playback.stderr.decode(errors="replace").strip()
            )
    finally:
        audio_path.unlink(missing_ok=True)


def main() -> None:
    logger.info("Listening on Redis queue: %s", REDIS_QUEUE)
    logger.info("TTS engine: local Piper neural voice and PipeWire")

    while True:
        try:
            result = redis_client.blpop(REDIS_QUEUE, timeout=0)
            if result:
                _, text = result
                logger.info("Speaking: %s", text)
                speak(text)
                logger.info("Done speaking")
        except redis.ConnectionError:
            logger.exception("Redis connection lost, retrying in 5 seconds")
            import time

            time.sleep(5)
        except KeyboardInterrupt:
            logger.info("TTS worker shutting down")
            break
        except Exception:
            logger.exception("Unable to speak queued message")


if __name__ == "__main__":
    main()
