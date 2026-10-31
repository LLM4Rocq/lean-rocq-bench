From Stdlib Require Import Arith.

Theorem lrb_smoke (a b : nat) : a + b = b + a.
Proof.
  exact (Nat.add_comm a b).
Qed.
