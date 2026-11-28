@echo off
rem ArcadeMaster: starts a Wii U game in this Cemu with the FULL path of its .rpx (Cemu 2.x reads a relative -g path
rem from the folder it was started in; the old per-game .bat files gave "..\..\collections\..." and 2.0-88 answered
rem "Unable to launch game", 2026-11-28). Sits in the frontend copy's emulators\Cemu; the frontend's Wii U launcher
rem calls it with the game's name: am-wiiu.bat "<item>". The game is a folder <roms>\<item>\code\*.rpx, as before.
setlocal
set "CEMU=%~dp0"
for %%r in ("%CEMU%..\..\collections\Nintendo Wii U\roms") do set "ROMS=%%~fr"
set "RPX="
for %%f in ("%ROMS%\%~1\code\*.rpx") do set "RPX=%%~ff"
if not defined RPX (
  echo no .rpx in "%ROMS%\%~1\code"
  exit /b 1
)
cd /d "%CEMU%"
start "" /wait "%CEMU%Cemu.exe" -f -g "%RPX%"
