@echo off
set "PATH=D:\Suresh R\flutter-sdk\flutter_windows_3.38.5-stable\flutter\bin;C:\Users\Suresh R\AppData\Local\Android\Sdk\platform-tools;%PATH%"
cd /d "%~dp0"
call flutter build apk --release
if errorlevel 1 goto :eof
copy /y "build\app\outputs\flutter-apk\app-release.apk" "D:\Suresh R\client_projects\sap_terminal-release-v8.1.apk"
adb -s 9213b7331020 install -r "D:\Suresh R\client_projects\sap_terminal-release-v8.1.apk"
adb -s 9213b7331020 shell monkey -p com.example.sap_terminal -c android.intent.category.LAUNCHER 1
echo V81 DONE
