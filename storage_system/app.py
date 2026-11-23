"""
Главный Flask-сервер системы автоматического хранения посылок
"""
from flask import Flask, render_template, request, jsonify
from datetime import datetime
from config import Config
from database import Database
from grbl_controller import GRBLController
from gcode_generator import GCodeGenerator

app = Flask(__name__)
app.config['SECRET_KEY'] = Config.SECRET_KEY

# Инициализация компонентов
db = Database()
grbl = GRBLController()
gcode_gen = GCodeGenerator()


@app.route('/')
def index():
    """Главная страница - визуализация ячеек"""
    cells = db.get_all_cells()
    stats = db.get_system_stats()
    return render_template('index.html', cells=cells, stats=stats, 
                          demo_mode=Config.DEMO_MODE)


@app.route('/register', methods=['POST'])
def register_package():
    """Регистрация посылки"""
    try:
        cell_id = int(request.form.get('cell_id'))
        package_id = request.form.get('package_id')
        weight = float(request.form.get('weight', 0))
        dimensions = request.form.get('dimensions', '0x0x0')
        
        success, message = db.register_package(cell_id, package_id, weight, dimensions)
        
        return jsonify({
            'success': success,
            'message': message
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'message': f'Ошибка: {str(e)}'
        }), 400


@app.route('/retrieve/<int:cell_id>', methods=['POST'])
def retrieve_package(cell_id):
    """Выдача посылки"""
    try:
        cell = db.get_cell_by_id(cell_id)
        if not cell:
            return jsonify({'success': False, 'message': 'Ячейка не найдена'}), 404
        
        # Генерация G-code
        gcode_commands = gcode_gen.generate_retrieve_sequence(cell['row'], cell['col'])
        
        # Выполнение команд
        if not grbl.execute_sequence(gcode_commands):
            return jsonify({'success': False, 'message': 'Ошибка выполнения команд'}), 500
        
        # Обновление БД
        success, message, package_id = db.retrieve_package(cell_id)
        
        return jsonify({
            'success': success,
            'message': message,
            'package_id': package_id
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'message': f'Ошибка: {str(e)}'
        }), 500


@app.route('/log')
def log():
    """Страница журнала операций"""
    operations = db.get_operations_log(limit=100)
    return render_template('log.html', operations=operations)


@app.route('/monitor')
def monitor():
    """Страница мониторинга"""
    stats = db.get_system_stats()
    return render_template('monitor.html', stats=stats, demo_mode=Config.DEMO_MODE)


@app.route('/api/status')
def api_status():
    """API для получения статуса системы"""
    cells = db.get_all_cells()
    stats = db.get_system_stats()
    
    return jsonify({
        'demo_mode': Config.DEMO_MODE,
        'arduino_connected': grbl.connected,
        'cells': cells,
        'stats': stats
    })


@app.route('/api/cells')
def api_cells():
    """API для получения списка ячеек"""
    cells = db.get_all_cells()
    return jsonify({'cells': cells})


if __name__ == '__main__':
    # Инициализация системы
    print("="*60)
    print("📦 СИСТЕМА АВТОМАТИЧЕСКОГО ХРАНЕНИЯ ПОСЫЛОК")
    print("="*60)
    
    if Config.DEMO_MODE:
        print("🎭 РЕЖИМ: ДЕМО (без Arduino)")
    else:
        print("🔧 РЕЖИМ: РЕАЛЬНЫЙ (с Arduino)")
    
    grbl.connect()
    print("="*60)
    
    print("\n🌐 Веб-интерфейс: http://localhost:5000")
    print("📋 Журнал: http://localhost:5000/log")
    print("📊 Мониторинг: http://localhost:5000/monitor")
    print("\nНажмите Ctrl+C для остановки\n")
    
    app.run(debug=Config.DEBUG, host='0.0.0.0', port=5000, use_reloader=False)