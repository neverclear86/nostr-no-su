import support/numbers

/// `below` は 0 から `count - 1` までを昇順に並べる。
pub fn below_lists_zero_up_to_one_less_than_the_count_test() {
  assert numbers.below(1) == [0]
  assert numbers.below(4) == [0, 1, 2, 3]
}

/// `up_to` は 1 から `count` までを昇順に並べる。
pub fn up_to_lists_one_up_to_the_count_test() {
  assert numbers.up_to(1) == [1]
  assert numbers.up_to(4) == [1, 2, 3, 4]
}

/// 件数が 0 以下なら、降順に進まず空にする。
pub fn a_count_of_zero_or_less_is_empty_test() {
  assert numbers.below(0) == []
  assert numbers.below(-2) == []
  assert numbers.up_to(0) == []
  assert numbers.up_to(-2) == []
}
