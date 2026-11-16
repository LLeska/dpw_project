"""
Генератор G-кода для управления платформой
"""
from config import Config


class GCodeGenerator:
    def __init__(self):
        self.cell_width = Config.CELL_WIDTH
        self.cell_height = Config.CELL_HEIGHT
        self.offset_x = Config.OFFSET_X
        self.offset_z = Config.OFFSET_Z
        self.travel_speed = Config.TRAVEL_SPEED
        self.extract_speed = Config.EXTRACT_SPEED
        self.extract_distance = Config.EXTRACT_DISTANCE
        self.drop_off_x = Config.DROP_OFF_X
        self.drop_off_z = Config.DROP_OFF_Z
    
    def get_cell_coords(self, row: int, col: int) -> tuple:
        """Вычисляет координаты X и Z для конкретной ячейки"""
        x = self.offset_x + (col * self.cell_width)
        z = self.offset_z + (row * self.cell_height)
        return x, z
    
    def move_to_cell(self, row: int, col: int) -> list:
        """Генерирует G-code для перемещения платформы к ячейке"""
        x, z = self.get_cell_coords(row, col)
        return [
            f"; --- Перемещение к ячейке [Ряд:{row}, Столбец:{col}] ---",
            f"G0 X{x:.2f} Z{z:.2f} F{self.travel_speed}"
        ]
    
    def extract_package(self) -> list:
        """Генерирует G-code для извлечения посылки (выдвижение оси Y)"""
        return [
            f"; --- Извлечение посылки ---",
            f"G1 Y{self.extract_distance:.2f} F{self.extract_speed}",
            "G4 P0.5",
            f"G1 Y0.0 F{self.travel_speed}"
        ]
    
    def move_to_drop_off(self) -> list:
        """Перемещение в зону выдачи"""
        return [
            f"; --- Перемещение в зону выдачи ---",
            f"G0 X{self.drop_off_x:.2f} Z{self.drop_off_z:.2f} F{self.travel_speed}"
        ]
    
    def go_home(self) -> list:
        """Возврат в домашнее положение"""
        return [
            "; --- Возврат домой ---",
            "G0 X0 Y0 Z0"
        ]
    
    def generate_retrieve_sequence(self, row: int, col: int) -> list:
        """Полная последовательность для выдачи посылки"""
        commands = []
        commands.extend(self.move_to_cell(row, col))
        commands.extend(self.extract_package())
        commands.extend(self.move_to_drop_off())
        return commands
    
    def generate_store_sequence(self, row: int, col: int) -> list:
        """Полная последовательность для загрузки посылки"""
        commands = []
        commands.extend(self.move_to_cell(row, col))
        commands.extend(self.extract_package())
        commands.extend(self.go_home())
        return commands