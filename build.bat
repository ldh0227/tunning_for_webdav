@echo off
echo Installing PyInstaller...
pip install pyinstaller

echo.
echo Building the executable...
pyinstaller --onefile --name WebDAV_Stress_Test py_webdav_stress_test.py

echo.
echo Build complete. The executable can be found in the 'dist' folder.
pause
