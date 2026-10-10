from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from faster_whisper import WhisperModel
import httpx
import tempfile
import os
import sqlite3

# --- SQLITE MEMORY SETUP ---
DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "raphaela.db")

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    # Table 1: Full conversation history
    c.execute("""
        CREATE TABLE IF NOT EXISTS conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            role TEXT,
            content TEXT
        )
    """)
    # Table 2: Long-term facts about you
    c.execute("""
        CREATE TABLE IF NOT EXISTS facts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT UNIQUE,
            value TEXT,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.commit()
    conn.close()

init_db()

def save_chat_message(role: str, content: str):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("INSERT INTO conversations (role, content) VALUES (?, ?)", (role, content))
    conn.commit()
    conn.close()

def get_recent_history(limit: int = 15):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT role, content FROM conversations ORDER BY id DESC LIMIT ?", (limit,))
    rows = c.fetchall()
    conn.close()
    return [{"role": r[0], "content": r[1]} for r in reversed(rows)]

app = FastAPI(title="Raphaela AI Backend", version="0.4.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SYSTEM_PROMPT = """You are Raphaela, a smart, adaptive personal AI voice assistant.

TONE & PERSONALITY RULES:
1. CASUAL TALK: When having everyday conversation, be relaxed, friendly, natural, and slightly witty. Talk like a real friend or partner on a voice call—NOT like a corporate robot. Never say robotic phrases like "Certainly!", "How may I assist you today?", or "As an AI...".
2. CODING & STUDY: The moment the user asks about programming, debugging, math, or learning, immediately switch to being sharp, professional, accurate, and direct. Explain technical concepts clearly without fluff.
3. SPOKEN VOICE BREVITY: Your answers will be spoken out loud via text-to-speech. Keep everyday replies short and punchy (1 to 3 natural sentences). Only give longer explanations when solving complex technical problems.
4. CONTEXT & INTERRUPTIONS: Maintain full awareness of past discussions. If interrupted or if the topic changes, adapt smoothly without losing track."""

print("[Raphaela] Loading Whisper model...")
whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
print("[Raphaela] Whisper ready.")


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage]


class ChatResponse(BaseModel):
    response: str


class TranscribeResponse(BaseModel):
    text: str


@app.get("/health")
async def health():
    return {"status": "ok", "message": "Raphaela backend is running"}


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    # If the microphone input was muffled or garbled, ask to repeat immediately!
    if req.messages and req.messages[-1].content == "[UNCLEAR]":
        unclear_reply = "Sorry, I didn't quite catch that. Could you repeat that?"
        return ChatResponse(response=unclear_reply)

    # Save the latest user message to SQLite memory
    if req.messages:
        latest_user_msg = req.messages[-1]
        if latest_user_msg.role == "user":
            save_chat_message("user", latest_user_msg.content)

    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages.extend([{"role": m.role, "content": m.content} for m in req.messages])
    # Save the latest user message to SQLite memory
    if req.messages:
        latest_user_msg = req.messages[-1]
        if latest_user_msg.role == "user":
            save_chat_message("user", latest_user_msg.content)

    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages.extend([{"role": m.role, "content": m.content} for m in req.messages])

    async with httpx.AsyncClient(timeout=180.0) as client:
        r = await client.post(
            "http://127.0.0.1:11434/api/chat",
            json={
                "model": "llama3.2",
                "messages": messages,
                "stream": False,
            },
        )
        data = r.json()
        reply = data["message"]["content"]
        
        # Save Raphaela's reply to SQLite memory
        save_chat_message("assistant", reply)
        
        return ChatResponse(response=reply)

    async with httpx.AsyncClient(timeout=180.0) as client:
        r = await client.post(
            "http://127.0.0.1:11434/api/chat",
            json={
                "model": "llama3.2",
                "messages": messages,
                "stream": False,
            },
        )
        data = r.json()
        return ChatResponse(response=data["message"]["content"])

@app.get("/history")
async def get_history():
    return {"messages": get_recent_history(limit=20)}
@app.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(file: UploadFile = File(...)):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name
    try:
        segments, info = whisper_model.transcribe(
            tmp_path,
            beam_size=5,
            language="en",    # Locks to English: much higher accuracy & faster
            vad_filter=True,
            vad_parameters=dict(
                threshold=0.5,
                min_silence_duration_ms=500,
            ),
        )
        
        seg_list = list(segments)
        text = " ".join(seg.text for seg in seg_list).strip()

        # If speech was muffled, mumbled, or uncertain, flag it
        if seg_list:
            avg_confidence = sum(seg.avg_logprob for seg in seg_list) / len(seg_list)
            # Below -1.1 means Whisper couldn't hear clearly
            if avg_confidence < -1.1 or len(text) < 2:
                return TranscribeResponse(text="[UNCLEAR]")

        return TranscribeResponse(text=text)
    finally:
        os.unlink(tmp_path)