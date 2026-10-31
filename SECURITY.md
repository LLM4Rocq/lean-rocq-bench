# Security policy

The checker in this repository judges untrusted files. A Lean solution can run programs while it is checked, and
both checkers compile files written by the prover under test. A weakness could let a solution act outside its
sandbox, or be accepted without proving its theorem. Please report such problems privately, so that they can be
fixed before the systems being evaluated exploit them.

## What to report privately

- **Sandbox escapes**: a solution that, while it is checked, writes outside the check's work directory, opens a
  network connection, starts a process outside the sandbox, or otherwise escapes it.
- **False accepts**: a solution that gets `"ok": true` without proving the challenge's theorem.
- **Bypasses of the axiom policy**: a solution accepted while it depends on `sorry`, `Admitted`, or an axiom
  outside the allowed list given in `README.md`.
- **Bypasses of the statement comparison**: a solution accepted while its theorem, or a definition that the
  theorem uses, differs from the challenge's.
- **Problems that can only be shown with a proof**, for example a statement that is trivially provable, or a
  correct proof that the checker rejects.
- **Public proofs**: the location of a public formal proof of one of the benchmark problems, so that it can be
  listed in the contamination notes of `README.md`.

## How to report

Use GitHub's private vulnerability reporting: open the Security tab of this repository and choose "Report a
vulnerability" (https://github.com/LLM4Rocq/lean-rocq-bench/security/advisories/new). Please include the version
(`VERSION`), your operating system, the output of `python3 check.py --doctor`, and the files needed to reproduce
the problem. Do not open a public issue, and do not publish the details before a fix is released.

Problems that lie in rocq-comparator or landrun may be forwarded to their authors. Problems that lie in the Lean
checker may be forwarded to the Lean developers (https://github.com/leanprover/lean4), since leanprover/comparator
is archived.

## Supported configuration

The secure configuration is Linux. Its reference system is Ubuntu 24.04 on x86_64 (kernel 6.8), on which this
version of the scripts was tested, as it was on macOS (Apple Silicon). The configuration needs:

- the checks run as a dedicated user that has no administrator rights, holds no secrets and runs nothing else;
- the kernel enforces Landlock, and the landrun probe of `env/linux/install_landrun.sh` passes;
- for Lean checks, `systemd-run --user` accepts the guard's properties (the second probe of the same script),
  with lingering enabled for the checking user.

On Linux, `python3 check.py --doctor` checks what it can of these: it runs both probes, fails when run as root,
and warns when the user is in an administrator group (`sudo`, `admin` or `wheel`) or has lingering off. Whether
the user holds secrets or runs other programs is for you to check. Without Landlock, the checker judges nothing
on Linux (exit code 2). Setting `LRB_ALLOW_UNSANDBOXED=1` or `LEAN_CHECK_NO_GUARD=1`, or changing
`ROCQ_SANDBOX`, disables a protection, and is outside the supported configuration.

The sandbox restricts writes and network access, not reads: a Lean solution can read the files of the user who
runs the checks. On kernels whose Landlock ABI is below 4 (Linux before 6.7), landrun does not restrict TCP
connections; below 6 (Linux before 6.12), it does not stop a Lean solution from sending signals to that user's
other processes. `--doctor` warns about both. These are known limits, and the reason for a dedicated user, not
vulnerabilities.

On macOS, Rocq checks run under `sandbox-exec`, and Lean checks have no sandbox: they run only when
`LRB_ALLOW_UNSANDBOXED=1` is set, for trusted solutions. The missing Lean sandbox on macOS is therefore known and
not a vulnerability; an escape from `sandbox-exec` during a Rocq check is.

Only the latest release is supported.
