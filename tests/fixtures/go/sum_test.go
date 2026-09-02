package fixture

import "testing"

func TestSum(t *testing.T) {
	if Sum(1, 2) != 3 {
		t.Fatal("expected 3")
	}
	if Sum(-1, 1) != 0 {
		t.Fatal("expected 0")
	}
	if Sum(-5, -3) != -8 {
		t.Fatal("expected -8")
	}
}
