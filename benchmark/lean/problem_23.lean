import Mathlib

abbrev problem_23_solution : ℕ := 13

theorem problem_23 : IsLeast {n | ∀ f : Fin n → Fin 12, ∃ a b, a ≠ b ∧ f a = f b} problem_23_solution := by sorry
