from pkg.sum import sum_


def test_positive() -> None:
    assert sum_(1, 2) == 3


def test_zeros() -> None:
    assert sum_(0, 0) == 0


def test_negatives() -> None:
    assert sum_(-5, -3) == -8
