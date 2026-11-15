"""
Контроллер для связи с Arduino через GRBL
"""
import serial
import time
from typing import List
from config import Config


class GRBLController:
    def __init__(self):
        self.port = Config.SERIAL_PORT
        self.baud = Config.BAUD_RATE
        self.demo_mode = Config.DEMO_MODE
        self.serial_conn = None
        self.connected = False
    
    def connect(self) -> bool:
        """Подключение к Arduino"""
        if self.demo_mode:
            print("🎭 [ДЕМО] Подключение к GRBL пропущено")
            self.connected = True
            return True
        
        try:
            self.serial_conn = serial.Serial(self.port, self.baud, timeout=2)
            time.sleep(2)
            
            # Сброс и ожидание приветствия
            self.serial_conn.write(b'\r\n\r\n')
            time.sleep(1)
            
            while self.serial_conn.in_waiting:
                line = self.serial_conn.readline().decode('utf-8').strip()
                if line:
                    print(f"GRBL: {line}")
            
            # Разблокировка
            self._send_raw('$X')
            self.connected = True
            print("✅ GRBL подключен и разблокирован")
            return True
            
        except Exception as e:
            print(f"❌ Ошибка подключения: {e}")
            self.connected = False
            return False
    
    def disconnect(self):
        """Отключение от Arduino"""
        if self.serial_conn and self.serial_conn.is_open:
            self.serial_conn.close()
        self.connected = False
        print("🔌 Отключено от GRBL")
    
    def _send_raw(self, command: str) -> bool:
        """Отправка одной строки и ожидание ответа"""
        if self.demo_mode:
            print(f"🎭 [ДЕМО] -> {command}")
            time.sleep(0.3)
            return True
        
        try:
            self.serial_conn.write((command + '\n').encode())
            
            while True:
                response = self.serial_conn.readline().decode('utf-8').strip()
                if response == 'ok':
                    return True
                elif response.startswith('error'):
                    print(f"⚠️ Ошибка GRBL: {response}")
                    return False
                elif response.startswith('ALARM'):
                    print(f"🚨 ТРЕВОГА GRBL: {response}")
                    return False
        except Exception as e:
            print(f"❌ Ошибка отправки: {e}")
            return False
    
    def execute_sequence(self, gcode_list: List[str]) -> bool:
        """Выполнение последовательности G-code команд"""
        print("\n" + "="*50)
        for cmd in gcode_list:
            if cmd.startswith(';') or not cmd.strip():
                continue
            
            success = self._send_raw(cmd)
            if not success:
                print("🛑 Выполнение прервано из-за ошибки!")
                return False
        print("="*50 + "\n")
        return True
    
    def emergency_stop(self):
        """Аварийная остановка"""
        if not self.demo_mode and self.serial_conn:
            self.serial_conn.write(b'!')
            print("🚨 АВАРИЙНАЯ ОСТАНОВКА!")