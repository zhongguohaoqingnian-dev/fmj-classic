class_name ChapterItemDetails
extends RefCounted
## Shared read-only player descriptions. Values follow ChapterCombat, not prose parsing.

const Combat = preload("res://src/chapter1/chapter_combat.gd")
const SLOT_NAMES := ["佩饰一", "佩饰二", "护腕", "鞋履", "武器", "衣服", "披风", "头饰"]
const STAT_NAMES := {"max_hp": "生命上限", "max_mp": "真气上限", "attack": "攻击", "defense": "防御", "speed": "身法", "lingli": "灵力", "luck": "吉运", "hp_per_round": "每回合生命", "mp_per_round": "每回合真气"}
const STATUS_NAMES := {8: "中毒", 4: "混乱", 2: "封魔", 1: "昏睡"}

static func goods_kind_name(goods: Dictionary) -> String:
	return str({1: "头饰", 2: "衣服", 3: "鞋履", 4: "披风", 5: "护腕", 6: "佩饰", 7: "武器", 8: "投掷道具", 9: "恢复药品", 10: "复苏药品", 11: "成长药品", 12: "战斗增益", 13: "特殊道具", 14: "剧情物品"}.get(_kind(goods), "物品"))

static func slot_name(slot: int) -> String:
	return SLOT_NAMES[slot] if slot >= 0 and slot < SLOT_NAMES.size() else "装备栏"

static func goods_text(goods: Dictionary) -> String:
	if goods.is_empty(): return "暂无物品资料。"
	var lines: Array[String] = [_description(goods), "类型：" + goods_kind_name(goods)]
	var kind := _kind(goods)
	if kind >= 1 and kind <= 7:
		var bonuses := _stat_effects(goods)
		lines.append("装备属性：" + ("、".join(bonuses) if not bonuses.is_empty() else "无基础属性变化"))
		if kind == 6:
			lines.append("位置：佩饰一或佩饰二，可选择替换位置。")
		if kind in [1, 2, 3, 4, 5] and _mask(goods) != 0:
			lines.append("免疫：" + _statuses(_mask(goods)))
		if kind == 7:
			if _mask(goods) != 0: lines.append("攻击有机会附加：" + _statuses(_mask(goods)) + _status_duration(goods))
			var damage := _weapon_throw_damage(goods)
			if damage >= 0: lines.append("战斗投掷：消耗一件，对%s造成 %d 生命伤害。" % [_target(goods, false), damage])
	elif kind == 8:
		lines.append("战斗投掷 · " + _target(goods, false) + " · 消耗一件")
		_append_damage(lines, goods, false)
		if _mask(goods) != 0: lines.append("有机会附加：" + _statuses(_mask(goods)) + _status_duration(goods))
	elif kind == 9:
		lines.append("探索、战斗均可使用 · " + _target(goods, true) + " · 仅对存活目标生效")
		var effects: Array[String] = []
		for stat in ["hp", "mp"]:
			var amount := _effect(goods, stat + "_effect")
			if amount != 0: effects.append("%s%s %d" % ["恢复" if amount > 0 else "减少", "生命" if stat == "hp" else "真气", absi(amount)])
		if not effects.is_empty(): lines.append("效果：" + "、".join(effects) + "，不超过当前上限。")
		if _mask(goods) != 0: lines.append("解除：" + _statuses(_mask(goods)))
	elif kind == 10:
		lines.append("探索、战斗均可使用 · " + _target(goods, true) + " · 仅对倒地目标生效")
		lines.append("复苏并恢复最大生命的 %d%%（向下取整）。" % int(goods.get("restore_percent_raw", _effect(goods, "hp_effect"))))
	elif kind == 11:
		lines.append("探索、战斗均可使用 · " + _target(goods, true))
		var changes := _stat_effects(goods)
		lines.append("永久改变：" + ("、".join(changes) if not changes.is_empty() else "无基础属性变化"))
		lines.append("提高生命或真气上限时，不同时恢复当前值。")
	elif kind == 12:
		lines.append("仅战斗中使用 · " + _target(goods, true))
		_append_modifiers(lines, goods, 1)
	elif kind == 13:
		lines.append("特殊用途：按当前场景的剧情条件使用。")
	elif kind == 14:
		lines.append("剧情用途：由相应事件使用，可在此查看说明。")
	if kind in [8, 9, 10, 11, 12]: lines.append("每次使用消耗一件；全体效果也只消耗一件。" if _for_all(goods) else "每次使用消耗一件。")
	return "\n".join(lines)

static func magic_text(spell: Dictionary) -> String:
	if spell.is_empty(): return "暂无术法资料。"
	var kind := _kind(spell)
	var lines: Array[String] = [_description(spell), "真气消耗：%d" % int(spell.get("cost_mp", spell.get("mp_cost", 0)))]
	lines.append(("探索、战斗均可施展" if kind in [3, 4] else "仅战斗中施展") + " · " + _target(spell, kind in [2, 3, 4]))
	match kind:
		1:
			_append_damage(lines, spell, true)
			if _mask(spell) != 0: lines.append("有机会附加：" + _statuses(_mask(spell)) + _status_duration(spell))
			_append_modifiers(lines, spell, -1)
		2:
			_append_modifiers(lines, spell, 1)
			lines.append("仅对存活目标生效。")
		3:
			if _effect(spell, "hp_effect") != 0: lines.append("恢复生命 %d，不超过当前生命上限。" % _effect(spell, "hp_effect"))
			if _mask(spell) != 0: lines.append("解除：" + _statuses(_mask(spell)))
			lines.append("仅对存活目标生效。")
		4:
			lines.append("复苏并恢复最大生命的 %d%%（向下取整）；仅对倒地目标生效。" % _effect(spell, "hp_effect"))
		5:
			lines.append("尝试取得敌人携带的物品，成功率受双方吉运影响。")
	lines.append("施法者须存活、未被封魔且真气足够。")
	return "\n".join(lines)

static func usable_actors_text(content: ChapterContent, goods: Dictionary) -> String:
	if _kind(goods) < 1 or _kind(goods) > 7: return ""
	var names: Array[String] = []
	var ids := content.actors.keys()
	ids.sort()
	for id in ids:
		var actor: Dictionary = content.actors[id]
		if _kind(actor) != 1: continue
		var number := int(actor.get("index", str(id).get_slice(":", 2)))
		if number > 0 and (int(goods.get("enable_mask_raw", 0)) & (1 << (number - 1))): names.append(str(actor.get("name", "角色")))
	return "可装备：" + ("、".join(names) if not names.is_empty() else "当前角色目录中无人可装备")

static func equipment_preview(content: ChapterContent, actor: Dictionary, inventory: Dictionary, id: String, slot: int = -1) -> Dictionary:
	# Only the incoming and worn records are needed; avoid copying the entire chapter on focus changes.
	var catalog: Dictionary = {}
	var equipment: Array = actor.get("equipment_ids", ["", "", "", "", "", "", "", ""])
	for item_id in equipment + [id]:
		if content.goods.has(str(item_id)): catalog[str(item_id)] = content.goods[str(item_id)]
	var combat := Combat.new()
	combat.configure({"goods_by_id": catalog})
	var result: Dictionary = combat.equip_actor(actor.duplicate(true), inventory.duplicate(true), id, slot)
	if not result.ok:
		var error := _equipment_error(str(result.error))
		return {"ok": false, "text": error, "slot": slot, "error": error, "changes": []}
	var selected_slot := slot
	if selected_slot < 0 and not id.is_empty():
		var kind := _kind(content.goods[id])
		selected_slot = (0 if str(equipment[0]).is_empty() else 1) if kind == 6 else int({1: 7, 2: 5, 3: 3, 4: 6, 5: 2, 7: 4}.get(kind, -1))
	var old_id := str(equipment[selected_slot])
	var old_name := str(content.goods.get(old_id, {}).get("name", "空位"))
	var new_name := str(content.goods.get(id, {}).get("name", "空位"))
	var lines: Array[String] = ["%s：%s → %s" % [slot_name(selected_slot), old_name, new_name]]
	var changes: Array = []
	for key in STAT_NAMES:
		var before := int(actor.get(key, 0))
		var after := int(result.actor.get(key, 0))
		if before != after:
			changes.append({"stat": key, "before": before, "after": after, "delta": after - before})
			lines.append("%s  %d → %d（%s）" % [STAT_NAMES[key], before, after, _signed(after - before)])
	if changes.is_empty(): lines.append("基础属性不变。")
	for stat in ["hp", "mp"]:
		if int(actor.get(stat, 0)) != int(result.actor.get(stat, 0)):
			lines.append("当前%s将调整为 %d。" % ["生命" if stat == "hp" else "真气", int(result.actor.get(stat, 0))])
	var before_mask := int(actor.get("immune_mask_raw", 0)) & 15
	var after_mask := int(result.actor.get("immune_mask_raw", 0)) & 15
	if before_mask != after_mask: lines.append("免疫：%s → %s" % [_statuses(before_mask), _statuses(after_mask)])
	if selected_slot == 4:
		var old_attack_mask := int(actor.get("attack_mask_raw", 0)) & 15
		var new_attack_mask := int(result.actor.get("attack_mask_raw", 0)) & 15
		if old_attack_mask != new_attack_mask: lines.append("攻击附加：%s → %s" % [_statuses(old_attack_mask), _statuses(new_attack_mask)])
	return {"ok": true, "text": "\n".join(lines), "slot": selected_slot, "error": "", "changes": changes, "actor": result.actor, "inventory": result.inventory, "old_id": old_id}

static func _description(resource: Dictionary) -> String:
	var description := str(resource.get("description", "")).strip_edges()
	return description if not description.is_empty() else "暂无文字说明，具体效果见下方。"

static func _stat_effects(goods: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for stat in STAT_NAMES:
		if _kind(goods) == 11 and stat not in Combat.STAT_KEYS: continue
		var amount: int
		if _kind(goods) == 11: amount = int(goods.get(stat + "_effect", goods.get(stat, 0)))
		elif stat in ["max_hp", "max_mp"]: amount = int(goods.get(stat + "_effect", goods.get(stat + "_delta", 0)))
		else: amount = int(goods.get(stat, 0))
		if amount != 0: out.append(STAT_NAMES[stat] + " " + _signed(amount))
	return out

static func _append_damage(lines: Array[String], resource: Dictionary, is_magic: bool) -> void:
	for stat in ["hp", "mp"]:
		var amount := _effect(resource, stat + "_effect")
		if amount == 0: continue
		var name := "生命" if stat == "hp" else "真气"
		lines.append("%s%s伤害 %d%s" % ["基础" if is_magic else "", name, absi(amount), "，并吸取至施用者。" if amount < 0 else "。"])
	if is_magic: lines.append("实际伤害受双方灵力、命中和战斗状态影响。")

static func _append_modifiers(lines: Array[String], resource: Dictionary, direction: int) -> void:
	var parts: Array[String] = []
	for stat in ["attack", "defense", "speed"]:
		var percent := int(resource.get(stat + "_percent", 0)) * direction
		if percent != 0: parts.append(STAT_NAMES[stat] + " " + _signed(percent) + "%")
	if not parts.is_empty(): lines.append("战斗效果：%s，持续 %d 回合；同属性增益或减益会被替换。" % ["、".join(parts), _rounds(resource)])

static func _equipment_error(error: String) -> String:
	if "restriction excludes" in error: return "此角色不能装备这件物品。"
	if "absent from inventory" in error: return "行囊中没有这件装备。"
	if "not equipment" in error: return "这件物品不能装备。"
	if "Decoration must" in error: return "佩饰只能放入佩饰一或佩饰二。"
	if "does not match" in error: return "这件装备与所选位置不符。"
	if "slot is required" in error: return "请先选择要卸下的装备位置。"
	return "装备资料不完整，暂时无法替换。"

static func _weapon_throw_damage(goods: Dictionary) -> int:
	var bytes: Array = goods.get("effect_bytes_raw", [])
	if bytes.size() != 8: return -1
	var damage := int(bytes[3]) & 127
	for key in {6: 8192, 7: 4096, 4: 2048, 5: 1024, 0: 512, 1: 256, 2: 128}:
		if int(bytes[key]) != 0: damage |= int({6: 8192, 7: 4096, 4: 2048, 5: 1024, 0: 512, 1: 256, 2: 128}[key])
	return damage

static func _target(resource: Dictionary, ally: bool) -> String:
	return ("我方全体" if ally else "敌方全体") if _for_all(resource) else ("我方单体" if ally else "敌方单体")

static func _statuses(mask: int) -> String:
	var names: Array[String] = []
	for bit in STATUS_NAMES:
		if mask & int(bit): names.append(STATUS_NAMES[bit])
	return "、".join(names) if not names.is_empty() else "无"

static func _status_duration(resource: Dictionary) -> String:
	return "（%d 回合）。" % (_rounds(resource) if _rounds(resource) > 0 else 256)

static func _signed(value: int) -> String:
	return ("+" if value >= 0 else "") + str(value)

static func _kind(resource: Dictionary) -> int:
	return int(resource.get("resource_type", resource.get("type", str(resource.get("id", "")).get_slice(":", 1))))

static func _for_all(resource: Dictionary) -> bool:
	return bool(resource.get("target_all", resource.get("all_targets", int(resource.get("effect_mask_raw", 0)) > 15)))

static func _effect(resource: Dictionary, key: String) -> int:
	return int(resource.get(key, resource.get("effects", {}).get(key, 0)))

static func _mask(resource: Dictionary) -> int:
	return int(resource.get("status_mask", resource.get("status_mask_raw", resource.get("effect_mask_raw", 0)))) & 15

static func _rounds(resource: Dictionary) -> int:
	return int(resource.get("rounds", resource.get("status_rounds", 0)))
