"""
Модуль работы с базой данных SQLite
"""
import sqlite3
from datetime import datetime
from typing import List, Dict, Optional, Tuple
from config import Config


class Database:
    def __init__(self, db_path: str = Config.DATABASE_PATH):
        self.db_path = db_path
        self.init_db()
    
    def get_connection(self):
        """Получить соединение с БД"""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn
    
    def init_db(self):
        """Инициализация базы данных"""
        conn = self.get_connection()
        cursor = conn.cursor()
        
        # Таблица ячеек
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS cells (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                row INTEGER NOT NULL,
                col INTEGER NOT NULL,
                x_coord REAL NOT NULL,
                z_coord REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'free',
                package_id TEXT,
                registered_at TIMESTAMP,
                UNIQUE(row, col)
            )
        ''')
        
        # Таблица посылок
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS packages (
                id TEXT PRIMARY KEY,
                cell_id INTEGER,
                weight REAL,
                dimensions TEXT,
                registered_at TIMESTAMP NOT NULL,
                retrieved_at TIMESTAMP,
                status TEXT NOT NULL DEFAULT 'stored',
                FOREIGN KEY (cell_id) REFERENCES cells(id)
            )
        ''')
        
        # Таблица журнала операций
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS operations_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TIMESTAMP NOT NULL,
                operation_type TEXT NOT NULL,
                cell_id INTEGER,
                package_id TEXT,
                status TEXT NOT NULL,
                details TEXT
            )
        ''')
        
        conn.commit()
        
        # Инициализация ячеек, если таблица пуста
        cursor.execute('SELECT COUNT(*) FROM cells')
        if cursor.fetchone()[0] == 0:
            self._init_cells(cursor)
        
        conn.commit()
        conn.close()
    
    def _init_cells(self, cursor):
        """Инициализация матрицы ячеек"""
        for row in range(Config.GRID_ROWS):
            for col in range(Config.GRID_COLS):
                x = Config.OFFSET_X + (col * Config.CELL_WIDTH)
                z = Config.OFFSET_Z + (row * Config.CELL_HEIGHT)
                cursor.execute('''
                    INSERT INTO cells (row, col, x_coord, z_coord, status)
                    VALUES (?, ?, ?, ?, 'free')
                ''', (row, col, x, z))
    
    def get_all_cells(self) -> List[Dict]:
        """Получить все ячейки"""
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT * FROM cells ORDER BY row, col')
        cells = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return cells
    
    def get_cell(self, row: int, col: int) -> Optional[Dict]:
        """Получить ячейку по координатам"""
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT * FROM cells WHERE row = ? AND col = ?', (row, col))
        cell = cursor.fetchone()
        conn.close()
        return dict(cell) if cell else None
    
    def get_cell_by_id(self, cell_id: int) -> Optional[Dict]:
        """Получить ячейку по ID"""
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT * FROM cells WHERE id = ?', (cell_id,))
        cell = cursor.fetchone()
        conn.close()
        return dict(cell) if cell else None
    
    def register_package(self, cell_id: int, package_id: str, weight: float = 0.0, 
                        dimensions: str = "0x0x0") -> Tuple[bool, str]:
        """Регистрация посылки в ячейке"""
        conn = self.get_connection()
        cursor = conn.cursor()
        
        try:
            # Проверка, что ячейка свободна
            cursor.execute('SELECT status FROM cells WHERE id = ?', (cell_id,))
            cell = cursor.fetchone()
            
            if not cell:
                return False, "Ячейка не найдена"
            
            if cell['status'] == 'occupied':
                return False, "Ячейка уже занята"
            
            # Проверка веса
            if weight > Config.MAX_PACKAGE_WEIGHT:
                return False, f"Превышена максимальная масса ({Config.MAX_PACKAGE_WEIGHT} кг)"
            
            # Обновление ячейки
            cursor.execute('''
                UPDATE cells 
                SET status = 'occupied', package_id = ?, registered_at = ?
                WHERE id = ?
            ''', (package_id, datetime.now(), cell_id))
            
            # Создание записи о посылке
            cursor.execute('''
                INSERT INTO packages (id, cell_id, weight, dimensions, registered_at, status)
                VALUES (?, ?, ?, ?, ?, 'stored')
            ''', (package_id, cell_id, weight, dimensions, datetime.now()))
            
            # Запись в журнал
            self._log_operation(cursor, 'REGISTER', cell_id, package_id, 'success', 
                              f'Вес: {weight}кг, Габариты: {dimensions}')
            
            conn.commit()
            return True, "Посылка успешно зарегистрирована"
            
        except Exception as e:
            conn.rollback()
            return False, f"Ошибка регистрации: {str(e)}"
        finally:
            conn.close()
    
    def retrieve_package(self, cell_id: int) -> Tuple[bool, str, Optional[str]]:
        """Выдача посылки из ячейки"""
        conn = self.get_connection()
        cursor = conn.cursor()
        
        try:
            # Получение информации о ячейке
            cursor.execute('SELECT * FROM cells WHERE id = ?', (cell_id,))
            cell = cursor.fetchone()
            
            if not cell:
                return False, "Ячейка не найдена", None
            
            if cell['status'] == 'free':
                return False, "Ячейка пуста", None
            
            package_id = cell['package_id']
            
            # Освобождение ячейки
            cursor.execute('''
                UPDATE cells 
                SET status = 'free', package_id = NULL, registered_at = NULL
                WHERE id = ?
            ''', (cell_id,))
            
            # Обновление статуса посылки
            cursor.execute('''
                UPDATE packages 
                SET status = 'retrieved', retrieved_at = ?
                WHERE id = ?
            ''', (datetime.now(), package_id))
            
            # Запись в журнал
            self._log_operation(cursor, 'RETRIEVE', cell_id, package_id, 'success', 
                              'Посылка выдана в зону загрузки')
            
            conn.commit()
            return True, f"Посылка {package_id} выдана", package_id
            
        except Exception as e:
            conn.rollback()
            return False, f"Ошибка выдачи: {str(e)}", None
        finally:
            conn.close()
    
    def _log_operation(self, cursor, operation_type: str, cell_id: int, 
                      package_id: str, status: str, details: str = ""):
        """Запись операции в журнал"""
        cursor.execute('''
            INSERT INTO operations_log (timestamp, operation_type, cell_id, package_id, status, details)
            VALUES (?, ?, ?, ?, ?, ?)
        ''', (datetime.now(), operation_type, cell_id, package_id, status, details))
    
    def get_operations_log(self, limit: int = 100) -> List[Dict]:
        """Получить журнал операций"""
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
            SELECT * FROM operations_log 
            ORDER BY timestamp DESC 
            LIMIT ?
        ''', (limit,))
        logs = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return logs
    
    def get_system_stats(self) -> Dict:
        """Получить статистику системы"""
        conn = self.get_connection()
        cursor = conn.cursor()
        
        cursor.execute('SELECT COUNT(*) FROM cells WHERE status = "free"')
        free_cells = cursor.fetchone()[0]
        
        cursor.execute('SELECT COUNT(*) FROM cells WHERE status = "occupied"')
        occupied_cells = cursor.fetchone()[0]
        
        cursor.execute('SELECT COUNT(*) FROM packages')
        total_packages = cursor.fetchone()[0]
        
        cursor.execute('SELECT COUNT(*) FROM operations_log')
        total_operations = cursor.fetchone()[0]
        
        conn.close()
        
        return {
            'free_cells': free_cells,
            'occupied_cells': occupied_cells,
            'total_cells': free_cells + occupied_cells,
            'total_packages': total_packages,
            'total_operations': total_operations
        }