cmake_minimum_required(VERSION 3.16.0)

# Versao da imagem (esp_app_desc_t.version) = FIRMWARE_VERSION de src/main.cpp
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/src/main.cpp" _fw_ver_line REGEX "^#define FIRMWARE_VERSION")
string(REGEX MATCH "\"([^\"]+)\"" _fw_ver_match "${_fw_ver_line}")
set(PROJECT_VER "${CMAKE_MATCH_1}")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# O nome do projeto vai para o descritor da imagem (esp_app_desc_t.project_name)
# e e verificado no OTA: so aceita imagem com o mesmo nome.
project(PescaPlus)
