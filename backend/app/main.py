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
import ctypes
import ctypes.wintypes
import time

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

LAST_SAVED_FILE = None
LAST_USED_FOLDER = None
PENDING_SCREENSHOT = None
PENDING_DELETE = None
PENDING_DELETE_ALL = None

def get_true_windows_shell_folder(folder_keyword: str) -> str:
    csidl = 0
    k = folder_keyword.lower()
    if "document" in k:
        csidl = 5
    elif "picture" in k or "photo" in k:
        csidl = 39
    elif "download" in k:
        return os.path.join(os.path.expanduser("~"), "Downloads")
    elif "personalai" in k or "project" in k:
        return r"C:\PersonalAI"

    buf = ctypes.create_unicode_buffer(ctypes.wintypes.MAX_PATH)
    ctypes.windll.shell32.SHGetFolderPathW(None, csidl, None, 0, buf)
    target = buf.value
    if target and os.path.exists(target):
        return target
    return os.path.join(os.path.expanduser("~"), "Desktop")

def resolve_target_folder(text: str) -> str:
    path_match = re.search(r"([a-zA-Z]:\\[^\s\*\?\"<>|]+)", text)
    if path_match:
        return path_match.group(1).rstrip("\\")
    return get_true_windows_shell_folder(text)

def force_delete_file(file_path: str) -> bool:
    if not os.path.exists(file_path):
        return False
    try:
        os.remove(file_path)
    except PermissionError:
        subprocess.run("taskkill /IM Microsoft.Photos.exe /F", shell=True, capture_output=True)
        time.sleep(0.4)
        try:
            os.remove(file_path)
        except Exception:
            return False
    except Exception:
        return False
    ctypes.windll.shell32.SHChangeNotify(0x00000004, 0x0005, file_path, None)
    return True

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
    return f"SELF-APPRAISAL MANIFEST: Active Modules: [OS Control, Dynamic File Management, Live Telemetry, Web Intelligence, SQLite Memory, Neural Voice]. Memory Status: {conv_count} logged conversations, {facts_count} long-term facts stored."

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
            target_dir = resolve_target_folder(target)
            os.startfile(target_dir)
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
    global PENDING_SCREENSHOT, PENDING_DELETE, PENDING_DELETE_ALL, LAST_SAVED_FILE, LAST_USED_FOLDER

    if req.messages and req.messages[-1].content == "[UNCLEAR]":
        unclear_reply = "Notice: Audio frequency indistinct. Could you repeat that, Master?"
        return ChatResponse(response=unclear_reply)

    latest_user_msg = req.messages[-1] if req.messages else None
    user_prompt = latest_user_msg.content.lower().strip() if latest_user_msg else ""

    if latest_user_msg and latest_user_msg.role == "user":
        save_chat_message("user", latest_user_msg.content)

    spoken_reply = ""

    if PENDING_SCREENSHOT is not None:
        target_dir = resolve_target_folder(user_prompt)
        os.makedirs(target_dir, exist_ok=True)
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"Raphaela_Screenshot_{timestamp}.png"
        save_file = os.path.join(target_dir, filename)

        PENDING_SCREENSHOT.save(save_file)
        LAST_SAVED_FILE = save_file
        LAST_USED_FOLDER = target_dir
        PENDING_SCREENSHOT = None

        os.startfile(save_file)
        folder_name = os.path.basename(target_dir)
        spoken_reply = f"Notice: Screenshot archived to your {folder_name} folder at {filename}, Master."

    elif PENDING_DELETE is not None or PENDING_DELETE_ALL is not None:
        if any(w in user_prompt for w in ["yes", "authorize", "confirm", "proceed", "do it", "sure", "delete"]):
            if PENDING_DELETE_ALL:
                count = 0
                for f in PENDING_DELETE_ALL:
                    if force_delete_file(f):
                        count += 1
                PENDING_DELETE_ALL = None
                LAST_SAVED_FILE = None
                spoken_reply = f"Notice: Authorization granted. All {count} screenshots have been permanently purged, Master."
            elif PENDING_DELETE:
                fname = os.path.basename(PENDING_DELETE)
                if force_delete_file(PENDING_DELETE):
                    LAST_SAVED_FILE = None
                    PENDING_DELETE = None
                    spoken_reply = f"Notice: Authorization confirmed. {fname} has been permanently removed from your system, Master."
                else:
                    spoken_reply = "Notice: The targeted file could not be accessed, Master."
                    PENDING_DELETE = None
        elif any(w in user_prompt for w in ["no", "cancel", "stop", "dont", "abort"]):
            PENDING_DELETE = None
            PENDING_DELETE_ALL = None
            spoken_reply = "Notice: Deletion authorization revoked, Master."
        else:
            spoken_reply = "Notice: Awaiting authorization, Master. Do you authorize me to delete this file? Say Yes or No."

    elif "screenshot" in user_prompt or "capture screen" in user_prompt:
        has_dest = any(f in user_prompt for f in ["document", "download", "picture", "desktop", "personalai", ":\\"])
        if has_dest:
            target_dir = resolve_target_folder(user_prompt)
            os.makedirs(target_dir, exist_ok=True)
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"Raphaela_Screenshot_{timestamp}.png"
            save_file = os.path.join(target_dir, filename)

            img = ImageGrab.grab()
            img.save(save_file)
            LAST_SAVED_FILE = save_file
            LAST_USED_FOLDER = target_dir
            os.startfile(save_file)
            folder_name = os.path.basename(target_dir)
            spoken_reply = f"Notice: Screenshot captured, Master. Saved to your {folder_name} folder at {filename}."
        else:
            PENDING_SCREENSHOT = ImageGrab.grab()
            spoken_reply = "Notice: Screen captured, Master. Where would you like me to save it? Desktop, Documents, Downloads, or another folder?"

    elif "delete" in user_prompt and any(w in user_prompt for w in ["screenshot", "that", "this", "it", "file", "again", "another"]):
        target_dir = resolve_target_folder(user_prompt) if any(f in user_prompt for f in ["document", "download", "desktop", "picture"]) else (LAST_USED_FOLDER or resolve_target_folder(""))
        
        if "all" in user_prompt:
            files = [os.path.join(target_dir, f) for f in os.listdir(target_dir) if f.startswith("Raphaela_Screenshot_")] if os.path.exists(target_dir) else []
            if files:
                PENDING_DELETE_ALL = files
                folder_name = os.path.basename(target_dir)
                spoken_reply = f"Notice: Found {len(files)} screenshots in your {folder_name} folder, Master. Confirming deletion of all files. Shall I proceed?"
            else:
                spoken_reply = "Notice: No screenshots found in that folder, Master."
        elif LAST_SAVED_FILE and os.path.exists(LAST_SAVED_FILE):
            PENDING_DELETE = LAST_SAVED_FILE
            fname = os.path.basename(LAST_SAVED_FILE)
            folder_name = os.path.basename(os.path.dirname(LAST_SAVED_FILE))
            spoken_reply = f"Notice: Authorization required. Master, do you authorize permanent deletion of {fname} from your {folder_name} folder?"
        else:
            files = [os.path.join(target_dir, f) for f in os.listdir(target_dir) if f.startswith("Raphaela_Screenshot_")] if os.path.exists(target_dir) else []
            if files:
                newest = max(files, key=os.path.getctime)
                PENDING_DELETE = newest
                fname = os.path.basename(newest)
                folder_name = os.path.basename(target_dir)
                spoken_reply = f"Notice: Authorization required. Found {fname} in your {folder_name} folder. Do you authorize me to delete it, Master?"
            else:
                spoken_reply = "Notice: No remaining screenshots found in that directory, Master."

    else:
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
        print(f"[Raphaela Voice Warning] Network glitch: {e}")

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
