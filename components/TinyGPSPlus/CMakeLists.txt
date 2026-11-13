# TinyGPSPlus 1.1.0 (mikalhart) — LGPL-2.1
# Copia local adaptada para ESP-IDF: Arduino.h trocado por tinygps_compat.h.
idf_component_register(
    SRCS "TinyGPS++.cpp"
    INCLUDE_DIRS "."
    REQUIRES esp_timer
)
