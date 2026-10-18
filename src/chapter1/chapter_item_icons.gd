extends RefCounted
## Original category emblems, not rarity or individual item artwork.
const FILES := ["quest","head","robe","boots","cloak","bracer","pendant","sword","dart","medicine","revive","elixir","charm","special","quest"]
static func texture(kind: int, magic := false, item_name := "") -> Texture2D:
	var key: String = "magic" if magic else FILES[clampi(kind,0,14)]
	if not magic:
		if kind in [2,4] and "甲" in item_name: key = "armor"
		elif kind == 7 and "刀" in item_name: key = "saber"
		elif kind in [9,10,11]:
			if "蛋" in item_name: key = "egg"
			elif "草" in item_name or "叶" in item_name or "针" in item_name: key = "herb"
			elif "果" in item_name: key = "fruit"
			elif "盐" in item_name: key = "salt"
			elif "丹" in item_name or "丸" in item_name: key = "pill"
	return load("res://assets/chapter2/inventory/%s.svg" % key)
