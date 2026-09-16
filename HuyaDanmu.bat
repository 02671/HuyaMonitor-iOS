@echo off
chcp 65001 >nul
cd /d "%~dp0"

if exist "%~dp0python\pythonw.exe" (
  start "" "%~dp0python\pythonw.exe" "%~dp0app.py"
  goto :eof
)
if exist "%~dp0python\python.exe" (
  "%~dp0python\python.exe" "%~dp0app.py"
  goto :eof
)

where pyw >nul 2>nul
if %errorlevel%==0 (
  start "" pyw -3 "%~dp0app.py"
  goto :eof
)
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 "%~dp0app.py"
  goto :eof
)

where pythonw >nul 2>nul
if %errorlevel%==0 (
  start "" pythonw "%~dp0app.py"
  goto :eof
)
where python >nul 2>nul
if %errorlevel%==0 (
  python "%~dp0app.py"
  goto :eof
)

echo 未找到 Python。请安装 Python 3.10+ 并勾选 Add python.exe to PATH，
echo 或把 embeddable Python 解压到本目录的 python 文件夹。
pause
