import Mathlib

open Set Function Filter Topology

theorem problem_42
(f : ℝ → ℝ)
(hf : Continuous f ∧ ∀ α > 0, Tendsto (fun n : ℕ ↦ f (n * α)) atTop (𝓝 0))
: (Tendsto f atTop (𝓝 0)) :=
sorry
