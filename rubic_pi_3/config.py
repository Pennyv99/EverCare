"""MemoryMate configuration."""

import os

from dotenv import load_dotenv


load_dotenv()

# Agent reasoning backend: "openai" (GPT-4.1) or "granite" (local Granite).
AGENT_BACKEND = os.getenv("AGENT_BACKEND", "openai").strip().lower()

# OpenAI GPT-4.1
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4.1")
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL") or None

# Local Granite through an OpenAI-compatible server (Ollama, vLLM, llama.cpp).
GRANITE_BASE_URL = os.getenv("GRANITE_BASE_URL", "http://127.0.0.1:11434/v1")
GRANITE_MODEL = os.getenv("GRANITE_MODEL", "granite3.3")
GRANITE_API_KEY = os.getenv("GRANITE_API_KEY", "ollama")

# Voice agent
WAKE_WORD = os.getenv("WAKE_WORD", "hey buddy")
WAKE_WORD_CHUNK_DURATION = float(os.getenv("WAKE_WORD_CHUNK_DURATION", "1.5"))
SPEECH_ENERGY_THRESHOLD = float(os.getenv("SPEECH_ENERGY_THRESHOLD", "0.015"))
SPEECH_RECORD_DURATION = int(os.getenv("SPEECH_RECORD_DURATION", "8"))
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "tiny")
MIC_SAMPLE_RATE = int(os.getenv("MIC_SAMPLE_RATE", "16000"))
MIC_CHANNELS = 1

# MCP agent
MCP_SERVER_COMMAND = "python3"
MCP_SERVER_ARGS = ["mcp_agent_server.py"]

# Redis
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
REDIS_TTS_QUEUE = "memorymate:tts"
REDIS_AGENT_QUEUE = "memorymate:agent"

# MongoDB
MONGO_URL = "mongodb://localhost:27017"
DB_NAME = "memorymate"

# Logging
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
LOG_FORMAT = "[%(asctime)s] [%(levelname)s] [%(name)s] %(message)s"
