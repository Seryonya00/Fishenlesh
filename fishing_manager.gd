class_name FishingManager
extends Node3D

## Ядро рыбалки (Этап 1, поплавочная упрощённо).
## Состояния: IDLE -> AIMING -> FLYING -> WAITING -> BITE -> FIGHT -> IDLE

enum State { IDLE, AIMING, FLYING, WAITING, BITE, FIGHT }

signal state_changed(new_state: State)
signal message_sent(text: String)
signal fight_update(tension: float, progress: float)

const CAST_MIN_DIST := 4.0
const CAST_MAX_DIST := 28.0
const AIM_TIME := 1.4
const BITE_WINDOW := 1.1

@export var player: Player
@export var water: Pond

var state: State = State.IDLE
var aim_power := 0.0

var _fish: FishData
var _bobber: MeshInstance3D
var _bite_timer := 0.0
var _wait_timer := 0.0
var _fly_from := Vector3.ZERO
var _fly_to := Vector3.ZERO
var _fly_t := 0.0
var _tension := 0.0
var _progress := 0.0
var _slack_time := 0.0
var _reeling := false
var _burst := 0.0
var _burst_timer := 0.0


func _ready() -> void:
	add_to_group("fishing")


func _process(delta: float) -> void:
	match state:
		State.AIMING:
			aim_power = minf(aim_power + delta / AIM_TIME, 1.0)
		State.FLYING:
			_fly_t += delta / 0.8
			if _fly_t >= 1.0:
				_bobber.global_position = _fly_to
				_wait_timer = randf_range(5.0, 15.0)
				_set_state(State.WAITING)
			elif _bobber:
				var p := _fly_from.lerp(_fly_to, _fly_t)
				p.y += sin(_fly_t * PI) * 2.0
				_bobber.global_position = p
		State.WAITING:
			_wait_timer -= delta
			if _bobber:
				_bobber.position.y = _fly_to.y + sin(Time.get_ticks_msec() * 0.004) * 0.02
			if _wait_timer <= 0.0:
				_fish = FishDB.roll(_hour(), GameState.selected_bait)
				if _fish == null:
					_finish("Нет клёва. Попробуйте другую наживку.")
				else:
					_bite_timer = BITE_WINDOW
					_set_state(State.BITE)
		State.BITE:
			_bite_timer -= delta
			if _bobber:
				_bobber.position.y = _fly_to.y - 0.15
			if _bite_timer <= 0.0:
				_finish("Поклёвку упустили...")
		State.FIGHT:
			_process_fight(delta)


func begin_aim() -> void:
	if state != State.IDLE and state != State.WAITING:
		return
	if float(GameState.line_durability) <= 0.0:
		_message("Леска порвана. Купите новую в магазине.")
		return
	aim_power = 0.0
	_set_state(State.AIMING)


func end_aim() -> void:
	if state != State.AIMING:
		return
	var cam := player.camera
	var max_dist := CAST_MAX_DIST + float(GameState.equipment.get("rod_cast_bonus", 0.0))
	var dist := lerpf(CAST_MIN_DIST, max_dist, aim_power)
	_fly_from = cam.global_transform.origin - cam.global_transform.basis.z * 0.5
	_fly_to = cam.global_transform.origin - cam.global_transform.basis.z * dist
	_fly_to.y = 0.05
	if not water.is_point_on_water(_fly_to):
		_message("Сюда не достать — цельтесь в воду.")
		_set_state(State.IDLE)
		return
	_fly_t = 0.0
	_spawn_bobber(_fly_from)
	_set_state(State.FLYING)


func strike() -> void:
	if state != State.BITE:
		return
	_tension = 0.35
	_progress = 0.0
	_slack_time = 0.0
	_burst = 0.0
	_burst_timer = 1.0
	_reeling = false
	_set_state(State.FIGHT)


func set_reeling(held: bool) -> void:
	_reeling = held and state == State.FIGHT


func _process_fight(delta: float) -> void:
	_burst_timer -= delta
	if _burst_timer <= 0.0:
		_burst = randf_range(0.2, 1.0)
		_burst_timer = randf_range(1.2, 3.0)
	_burst = move_toward(_burst, 0.0, delta * 0.7)
	var pull := _fish.strength * (0.55 + _burst)
	if _reeling:
		_tension += (pull * 0.55 - 0.2) * delta
		_progress += maxf(0.12, 0.30 - pull * 0.10) * delta
	else:
		_tension -= 0.5 * delta
	_tension = clampf(_tension, 0.0, 99.0)
	if _tension <= 0.001:
		_slack_time += delta
	else:
		_slack_time = 0.0
	fight_update.emit(_tension, clampf(_progress, 0.0, 1.0))
	var break_limit := float(GameState.equipment.get("line_strength", 1.0))
	if _tension >= break_limit:
		GameState.line_durability = maxf(0.0, GameState.line_durability - 20.0)
		_finish("Обрыв! Леска не выдержала натяжение.")
	elif _slack_time > 2.0:
		_finish("Рыба сошла — леска провисла.")
	elif _progress >= 1.0:
		_land_fish()


func _land_fish() -> void:
	var grams := randi_range(_fish.base_weight_g, _fish.max_weight_g)
	var price := maxi(1, grams * _fish.price_per_kg / 1000)
	var entry := {
		"fish_id": _fish.id,
		"name": _fish.display_name,
		"grams": grams,
		"trophy": _fish.trophy,
		"price": price,
	}
	if GameState.add_catch(entry):
		GameState.add_xp(maxi(1, grams / 100))
		GameState.line_durability = maxf(0.0, GameState.line_durability - 2.0)
		var tag := " [ТРОФЕЙ!]" if _fish.trophy else ""
		_finish("Поймано: %s (%d г)%s" % [_fish.display_name, grams, tag])
	else:
		_finish("Садок полон! Продайте улов в магазине.")


func _finish(text: String) -> void:
	_message(text)
	if _bobber:
		_bobber.visible = false
	_reeling = false
	_set_state(State.IDLE)


func _hour() -> int:
	return Time.get_datetime_dict_from_system().hour


func _set_state(s: State) -> void:
	state = s
	state_changed.emit(s)


func _message(text: String) -> void:
	message_sent.emit(text)


func _spawn_bobber(at: Vector3) -> void:
	if _bobber == null:
		_bobber = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.09
		sphere.height = 0.18
		_bobber.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.15, 0.15)
		_bobber.material_override = mat
		add_child(_bobber)
	_bobber.visible = true
	_bobber.global_position = at
