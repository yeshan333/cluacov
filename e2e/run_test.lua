local sample = require("sample")

-- Exercise classify: only test positive and zero, skip negative
assert(sample.classify(5) == "positive")
assert(sample.classify(0) == "zero")

-- Exercise abs: only test positive path (no branch taken)
assert(sample.abs(10) == 10)

-- Exercise clamp: only test within range
assert(sample.clamp(5, 1, 10) == 5)

-- Exercise sum: test with a non-empty list (loop runs)
assert(sample.sum({1, 2, 3}) == 6)

-- Exercise find: search for a value that exists
assert(sample.find({10, 20, 30}, 20) == true)

-- Exercise safe_div: only test non-zero divisor
assert(sample.safe_div(10, 2) == 5)

-- Exercise fizzbuzz: test fizzbuzz and fizz, skip buzz and plain number
assert(sample.fizzbuzz(15) == "fizzbuzz")
assert(sample.fizzbuzz(9) == "fizz")

-- Skip max_of_three entirely (no calls)

-- Exercise any_truthy: only first arg true (short-circuits, b/c never evaluated)
assert(sample.any_truthy(true, nil, nil) == "yes")

-- Exercise all_truthy: first two true, third false (partial short-circuit)
assert(sample.all_truthy(true, true, false) == "not all")

-- Exercise mixed_logic: only x>0 and y>0 path
assert(sample.mixed_logic(5, 3) == "match")

print("E2E test passed")
