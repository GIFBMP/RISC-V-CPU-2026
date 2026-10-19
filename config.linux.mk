# Course Dockerfile tools, available on PATH inside cpu2026:arm64.
# Command-line assignments take precedence.
APPIMAGE =
CXX = g++
BUILD_MAKE = make
BUILD = build/linux
JOBS = 6
MAX_CYCLES = 100000000
ASAP7_LIB = /opt/asap7/lib

include $(FRAMEWORK_DIR)/config.synth.mk
