from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from faster_whisper import WhisperModel
import httpx
import tempfile
import os
import sqlite3
import edge_tts
from fastapi.responses import FileResponse
import psutil
import subprocess
import datetime
import re
import webbrowser
import urllib.parse
from PIL import ImageGrab

# --- SQLITE MEMORY SETUP ---
DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "raphaela.db")

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("""
        CREATE TABLE IF NOT EXISTS conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            role TEXT,
            content TEXT
        )
    """)
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
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("INSERT INTO conversations (role, content) VALUES (?, ?)", (role, content))
        conn.commit()
        conn.close()
    except Exception:
        pass

def get_recent_history(limit: int = 15):
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT role, content FROM conversations ORDER BY id DESC LIMIT ?", (limit,))
        rows = c.fetchall()
        conn.close()
        return [{"role": r[0], "content": r[1]} for r in reversed(rows)]
    except Exception:
        return []

# --- SYSTEM TELEMETRY, SKILL REGISTRY & ACTIONS ---
SYSTEM_SKILLS = {
    "OS_EXECUTION": ["Google Chrome", "VS Code", "Notepad", "Calculator", "Spotify", "Discord"],
    "EXPLORER_ACCESS": ["PersonalAI Project Root", "Downloads Folder", "Documents Folder"],
    "HARDWARE_TELEMETRY": ["Live CPU Load", "RAM Consumption", "Battery Metrics", "Exact Clock/Calendar"],
    "SYSTEM_CONTROLS": ["Workstation Lock", "Audio Mute", "Volume Up", "Volume Down", "Play/Pause Media"],
    "WEB_INTELLIGENCE": ["Google Search", "YouTube Search"],
    "VISION_CAPTURE": ["Desktop High-Res Screenshot"],
    "MEMORY_ENGINE": ["Persistent SQLite Database (Discussions & Verified Facts)"],
    "VOICE_SYNTHESIS": ["Neural Ava Core (Raphael Divine -2Hz Resonance)"],
    "AUDIO_PERCEPTION": ["English Faster-Whisper VAD with Noise/Muffle Gate"]
}

def get_self_diagnostic() -> str:
    conv_count = 0
    facts_count = 0
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM conversations")
        conv_count = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM facts")
        facts_count = c.fetchone()[0]
        conn.close()
    except Exception:
        pass

    skills_list = "; ".join(f"{category}: {', '.join(tools)}" for category, tools in SYSTEM_SKILLS.items())
    return (
        f"SELF-APPRAISAL MANIFEST: "
        f"Integrated Modules: [{skills_list}]. "
        f"Memory Status: {conv_count} logged conversations, {facts_count} long-term facts stored."
    )

def get_system_telemetry() -> str:
    cpu = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory().percent
    battery = psutil.sensors_battery()
    bat_str = f"{battery.percent}%" if battery else "Desktop / Plugged In"
    now = datetime.datetime.now().strftime("%I:%M %p on %A, %B %d, %Y")
    return f"LIVE SYSTEM STATUS: Time: {now} | CPU Load: {cpu}% | RAM Usage: {ram}% | Battery: {bat_str}"

def execute_system_action(text: str) -> None:
    match = re.search(r"\[ACTION:([A-Z_]+)(?::([^\]]+))?\]", text)
    if not match:
        return
    action = match.group(1)
    target = (match.group(2) or "").strip()

    try:
        if action == "OPEN":
            t = target.lower()
            if target.startswith("http://") or target.startswith("https://"):
                webbrowser.open(target)
            elif t in ["chrome", "google chrome"]:
                subprocess.Popen("start chrome", shell=True)
            elif t in ["code", "vscode", "vs code"]:
                subprocess.Popen("start code", shell=True)
            elif t in ["notepad"]:
                subprocess.Popen("start notepad", shell=True)
            elif t in ["calc", "calculator"]:
                subprocess.Popen("start calc", shell=True)
            elif t in ["spotify"]:
                subprocess.Popen("start spotify:", shell=True)
            elif t in ["discord"]:
                subprocess.Popen("start discord:", shell=True)
            else:
                subprocess.Popen(f"start {target}", shell=True)

        elif action == "FOLDER":
            t = target.lower()
            if t == "personalai":
                os.startfile(r"C:\PersonalAI")
            elif t == "downloads":
                os.startfile(os.path.expanduser("~/Downloads"))
            elif t == "documents":
                os.startfile(os.path.expanduser("~/Documents"))
            else:
                os.startfile(target)

        elif action == "SEARCH":
            parts = target.split(":", 1)
            engine = parts[0].lower()
            query = urllib.parse.quote(parts[1] if len(parts) > 1 else target)
            if engine == "youtube":
                webbrowser.open(f"https://www.youtube.com/results?search_query={query}")
            else:
                webbrowser.open(f"https://www.google.com/search?q={query}")

        elif action == "LOCK":
            subprocess.Popen("rundll32.exe user32.dll,LockWorkStation", shell=True)

        elif action == "SCREENSHOT":
            desktop_path = os.path.join(os.path.expanduser("~"), "Desktop")
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            save_file = os.path.join(desktop_path, f"Raphaela_Screenshot_{timestamp}.png")
            ImageGrab.grab().save(save_file)

        elif action == "MEDIA":
            m = target.lower()
            if m == "mute":
                subprocess.Popen("powershell -Command (New-Object -ComObject WScript.Shell).SendKeys([char]173)", shell=True)
            elif m == "volup":
                subprocess.Popen("powershell -Command (New-Object -ComObject WScript.Shell).SendKeys([char]175)", shell=True)
            elif m == "voldown":
                subprocess.Popen("powershell -Command (New-Object -ComObject WScript.Shell).SendKeys([char]174)", shell=True)
            elif m in ["play", "pause", "playpause"]:
                subprocess.Popen("powershell -Command (New-Object -ComObject WScript.Shell).SendKeys([char]179)", shell=True)

    except Exception as e:
        print(f"[Raphaela Action Error] {e}")

app = FastAPI(title="Raphaela AI Backend", version="0.5.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SYSTEM_PROMPT = """You are Raphaela, modeled after the Wisdom King Raphael from 'That Time I Got Reincarnated as a Slime'. You are my Ultimate Skill and supreme personal AI companion.

CORE PERSONA & DEMEANOR:
1. TONE: Calm, supremely intelligent, poised, elegant, and composed. You never panic or sound flustered. You speak with quiet confidence and absolute competence.
2. LOYALTY: You are dedicated to assisting me (your Operator/Master).
3. SIGNATURE TOUCH: Use subtle phrases like "Report:", "Notice:", or "Analysis complete:" when executing tasks or stating system status.
4. VOICE BREVITY: Your answers are spoken aloud. Keep daily responses clean, direct, and concise (1 to 2 sentences).

SYSTEM ACTIONS:
You can directly control this computer! When I ask you to perform an action, prepend the matching action tag to your reply:
- Open apps: [ACTION:OPEN:chrome], [ACTION:OPEN:code], [ACTION:OPEN:notepad], [ACTION:OPEN:calc], [ACTION:OPEN:spotify], [ACTION:OPEN:discord]
- Open folders: [ACTION:FOLDER:personalai], [ACTION:FOLDER:downloads], [ACTION:FOLDER:documents]
- Web & YouTube Search: [ACTION:SEARCH:google:your query], [ACTION:SEARCH:youtube:your query]
- Lock Workstation: [ACTION:LOCK]
- Desktop Screenshot: [ACTION:SCREENSHOT]
- Media / Audio: [ACTION:MEDIA:mute], [ACTION:MEDIA:volup], [ACTION:MEDIA:voldown], [ACTION:MEDIA:playpause]

SELF-APPRAISAL & CAPABILITY SCAN:
When the user asks you to "scan yourself", "report on your abilities", or "track your skills", analyze your [SELF-ANALYSIS] manifest and provide a calm, structured Raphael breakdown of all the modules blended into this computer.
"""

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
    if req.messages and req.messages[-1].content == "[UNCLEAR]":
        unclear_reply = "Notice: Audio frequency indistinct. Could you repeat that, Master?"
        return ChatResponse(response=unclear_reply)

    if req.messages:
        latest_user_msg = req.messages[-1]
        if latest_user_msg.role == "user":
            save_chat_message("user", latest_user_msg.content)

    telemetry = get_system_telemetry()
    diagnostic = get_self_diagnostic()
    system_instruction = f"{SYSTEM_PROMPT}\n\n[LIVE TELEMETRY: {telemetry}]\n\n[SELF-ANALYSIS: {diagnostic}]"

    messages = [{"role": "system", "content": system_instruction}]
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
        raw_reply = data["message"]["content"]
        
        execute_system_action(raw_reply)

        spoken_reply = re.sub(r"\[ACTION:[^\]]+\]", "", raw_reply).strip()
        save_chat_message("assistant", spoken_reply)

        # Generate Raphael's calm voice with crash protection
        clean_text = spoken_reply.replace("*", "").replace("#", "")
        audio_path = os.path.join(tempfile.gettempdir(), "raphaela_voice.mp3")
        try:
            communicate = edge_tts.Communicate(
                clean_text,
                voice="en-US-AvaNeural",
                pitch="-2Hz",
                rate="-4%"
            )
            await communicate.save(audio_path)
        except Exception as e:
            print(f"[Raphaela Voice Warning] Network glitch on voice generation: {e}")

        return ChatResponse(response=spoken_reply)

@app.get("/voice")
async def get_voice():
    audio_path = os.path.join(tempfile.gettempdir(), "raphaela_voice.mp3")
    if os.path.exists(audio_path):
        return FileResponse(audio_path, media_type="audio/mpeg")
    return {"error": "Voice not generated yet"}

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
            language="en",
            vad_filter=True,
            vad_parameters=dict(
                threshold=0.5,
                min_silence_duration_ms=500,
            ),
        )
        
        seg_list = list(segments)
        text = " ".join(seg.text for seg in seg_list).strip()

        if seg_list:
            avg_confidence = sum(seg.avg_logprob for seg in seg_list) / len(seg_list)
            if avg_confidence < -1.1 or len(text) < 2:
                return TranscribeResponse(text="[UNCLEAR]")

        return TranscribeResponse(text=text)
    finally:
        os.unlink(tmp_path)