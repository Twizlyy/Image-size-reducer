@echo off
echo === Image Size Reducer - Build Script ===
echo.

echo [1/2] Installation des dependances...
pip install -r requirements.txt
if errorlevel 1 (
    echo ERREUR : pip install a echoue.
    pause
    exit /b 1
)

echo.
echo [2/2] Compilation de l'executable...
pyinstaller --onefile --windowed --name "ImageSizeReducer" main.py
if errorlevel 1 (
    echo ERREUR : PyInstaller a echoue.
    pause
    exit /b 1
)

echo.
if exist "dist\ImageSizeReducer.exe" (
    echo ============================================
    echo  Succes ! Executable : dist\ImageSizeReducer.exe
    echo ============================================
) else (
    echo ERREUR : L'executable n'a pas ete genere.
)
echo.
pause
