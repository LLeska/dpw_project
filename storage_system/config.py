"""
Конфигурация системы автоматического хранения посылок
"""

class Config:
    # Режим работы: True - без Arduino (симуляция), False - реальная Arduino
    DEMO_MODE = True
    
    # Настройки Serial для Arduino
    SERIAL_PORT = 'COM3'  # Замените на ваш порт (Linux: /dev/ttyUSB0)
    BAUD_RATE = 115200
    
    # Параметры матрицы ячеек
    GRID_ROWS = 2      # Количество строк (ось Z)
    GRID_COLS = 2      # Количество столбцов (ось X)
    
    # Физические размеры (в мм)
    CELL_WIDTH = 150.0      # Расстояние между центрами ячеек по X
    CELL_HEIGHT = 150.0     # Расстояние между центрами ячеек по Z
    OFFSET_X = 75.0         # Смещение первой ячейки от нуля по X
    OFFSET_Z = 75.0         # Смещение первой ячейки от нуля по Z
    
    # Параметры движения
    TRAVEL_SPEED = 1500     # Скорость быстрого перемещения (G0) для X и Z (мм/мин)
    EXTRACT_SPEED = 300     # Скорость медленного извлечения (G1) для Y (мм/мин)
    EXTRACT_DISTANCE = 80.0 # На сколько выдвигать ось Y (мм)
    
    # Зона выдачи (куда кладем посылку для робота)
    DROP_OFF_X = 0.0
    DROP_OFF_Z = 0.0
    
    # Ограничения по ТЗ
    MAX_PACKAGE_WEIGHT = 1.0        # кг
    MAX_PACKAGE_DIMENSIONS = (120, 80, 80)  # мм (Д x Ш x В)
    
    # База данных
    DATABASE_PATH = 'storage_system.db'
    
    # Flask
    SECRET_KEY = 'your-secret-key-change-in-production'
    DEBUG = True