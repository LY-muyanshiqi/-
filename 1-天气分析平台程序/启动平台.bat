@echo off
chcp 65001 >nul
cd /d "C:\Users\xiaoY\Desktop\公用\1-天气分析平台程序\weather-load-platform"
echo 🚀 启动天气分析平台...
echo.
D:\Users\xiaoY\AppData\python\python.exe -m streamlit run app.py --server.port 8501
pause
