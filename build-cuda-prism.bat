@echo off
setlocal
rem ---- PrismML llama.cpp fork CUDA build (Bonsai 2 ternary) ----
set "VSROOT=C:\Program Files\Microsoft Visual Studio\2022\Community"
set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9"
set "NINJA_DIR=C:\Python\Python311\Scripts"
set "PATH=%CUDA_PATH%\bin;%NINJA_DIR%;%PATH%"

call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] failed to initialise MSVC environment
  exit /b 1
)

cd /d "%~dp0llama.cpp-prism" || exit /b 1

set "CFG=-B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86 -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF"

if /I "%~1"=="build" goto :build
if /I "%~1"=="rebuild" goto :rebuild

echo [1/2] Configuring...
cmake %CFG% || exit /b 1
if /I not "%~1"=="configure" goto :build
exit /b 0

:build
echo [2/2] Building...
cmake --build build -j %NUMBER_OF_PROCESSORS% || exit /b 1
echo Copying CUDA runtime DLLs next to the binaries...
for %%D in (cudart64_12.dll cublas64_12.dll cublasLt64_12.dll nvrtc64_120_0.dll nvJitLink_120_0.dll) do (
  if exist "%CUDA_PATH%\bin\%%D" copy /y "%CUDA_PATH%\bin\%%D" build\bin\ >nul
)
echo Done. Binaries are in llama.cpp-prism\build\bin
exit /b 0

:rebuild
rmdir /s /q build
cmake %CFG% || exit /b 1
goto :build
