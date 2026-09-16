@echo off
chcp 65001 >nul
cd /d "%~dp0"

if exist "%~dp0python\python.exe" (
  "%~dp0python\python.exe" -m pip install -r "%~dp0requirements.txt"
  goto :done
)

where py >nul 2>nul
if %errorlevel%==0 (
  py -3 -m pip install -r "%~dp0requirements.txt"
  goto :done
)

where python >nul 2>nul
if %errorlevel%==0 (
  python -m pip install -r "%~dp0requirements.txt"
  goto :done
)

echo 未找到 Python，无法安装依赖。
pause
exit /b 1

:done
echo 依赖安装完成。双击 HuyaDanmu.bat 即可启动。
pause
