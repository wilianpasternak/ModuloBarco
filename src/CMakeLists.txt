FILE(GLOB_RECURSE app_sources ${CMAKE_SOURCE_DIR}/src/*.cpp)

idf_component_register(
    SRCS ${app_sources}
    INCLUDE_DIRS "."
    REQUIRES TinyGPSPlus esp_driver_gpio esp_driver_ledc esp_driver_uart
             esp_driver_i2c esp_driver_spi esp_adc nvs_flash app_update
             esp_timer esp_app_format bt
)
