class_name Det
## Deterministic hashing helpers. Everything in the infinite world derives from
## (world_seed, coordinates, salt) so any sector can be regenerated identically.

static func h(seed: int, a: int, b: int, salt: int = 0) -> int:
	# Vector4i hashing is murmur3-based and platform independent.
	return hash(Vector4i(seed, a, b, salt)) & 0x7FFFFFFF


static func h3(seed: int, a: int, b: int, c: int, salt: int = 0) -> int:
	return hash(Vector4i(seed ^ (salt * 0x9E3779B1), a, b, c)) & 0x7FFFFFFF


static func unit(seed: int, a: int, b: int, salt: int = 0) -> float:
	return float(h(seed, a, b, salt) & 0xFFFFFF) / float(0x1000000)


static func rng_for(seed: int, a: int, b: int, salt: int = 0) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = h(seed, a, b, salt)
	return r


static func key(sx: int, sy: int) -> Vector2i:
	return Vector2i(sx, sy)
