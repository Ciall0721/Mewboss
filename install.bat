@echo off
setlocal

REM ============================================================
REM  Sync the mod from this dev folder into the game's mods folder.
REM
REM  NOTE: This file is deliberately ASCII-only. A .bat containing
REM  UTF-8 Chinese text is mis-parsed by cmd.exe on a Chinese Windows
REM  (cmd reads the file as GBK), which turns comment lines into
REM  garbage commands. Keep it ASCII.
REM
REM  Why only the mod\ subfolder is synced:
REM  the game recursively scans mods\ for metadata.xml, so tools\,
REM  raw\ and doc\ must never end up there.
REM
REM  /XF disable.it keeps the in-game dev toggle from being deleted
REM  by the mirror.
REM ============================================================

set "SRC=%~dp0mod"
set "DST=D:\Steam\steamapps\common\The Binding of Isaac Rebirth\mods\mewboss"

echo.
echo   From: %SRC%
echo   To:   %DST%
echo.

if not exist "%DST%" mkdir "%DST%"

robocopy "%SRC%" "%DST%" /MIR /XF disable.it /NFL /NDL /NJH /NJS /NP
set RC=%ERRORLEVEL%

REM robocopy: exit codes 0-7 are success, 8+ are real errors.
REM NOTE: no parentheses may appear inside these echo lines -- an unescaped
REM ")" would close the if-block early and cmd errors out.
if %RC% GEQ 8 (
    echo.
    echo   [FAILED] robocopy returned %RC%
) else (
    echo.
    echo   [DONE] Synced to mods\mewboss
    echo.
    echo   In game, press the tilde key for the debug console, then:
    echo     luamod mewboss     hot-reload Lua - only needed for .lua changes
    echo     spawn 501          spawn the Zodiac boss
    echo.
    echo   Editing entities2.xml or .anm2 requires a FULL GAME RESTART.
    echo   luamod only reloads Lua.
)

endlocal
