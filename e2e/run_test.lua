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

print("E2E test passed")
