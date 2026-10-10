Set WshShell = CreateObject("WScript.Shell") 
WshShell.CurrentDirectory = "C:\PersonalAI\backend" 
WshShell.Run "C:\PersonalAI\backend\venv\Scripts\pythonw.exe run.py", 0, False 
WScript.Sleep 2000 
WshShell.CurrentDirectory = "C:\PersonalAI\frontend\build\windows\x64\runner\Release" 
WshShell.Run "frontend.exe", 1, False 
