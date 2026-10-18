class_name Checks
extends RefCounted
## JSON integers are decoded as floats. Validate before conversion, never truncate.

static func integer(value: Variant, minimum: int = -2147483648, maximum: int = 2147483647) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum

static func text(value: Variant) -> bool:
	return value is String and not value.is_empty()

static func success(value: Variant = null) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}

static func failure(message: String) -> Dictionary:
	return {"ok": false, "value": null, "error": message}

static func json_value(value: Variant, depth: int = 0) -> bool:
	if depth > 32:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return true
		TYPE_INT:
			return value >= -9007199254740991 and value <= 9007199254740991
		TYPE_FLOAT:
			return is_finite(value) and absf(value) <= float(9007199254740991)
		TYPE_ARRAY:
			for child in value:
				if not json_value(child, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not key is String or not json_value(value[key], depth + 1):
					return false
			return true
	return false
