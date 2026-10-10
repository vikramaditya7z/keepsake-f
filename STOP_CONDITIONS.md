# STOP_CONDITIONS.md — Safe Loop Boundaries & Circuit Breakers

To guarantee safety, maintain system integrity, and prevent runaway agent iterations, the KeepSake `/goal` loop must halt immediately when any of the following boundaries are triggered.

---

## 1. Goal Completion Halt

The agent must stop and declare the milestone complete when:
- All measurable acceptance criteria in [`GOAL.md`](file:///Users/vikramaditya/Disk/Projects/KeepSake/GOAL.md) have been satisfied.
- All verification gates in [`VERIFIER.md`](file:///Users/vikramaditya/Disk/Projects/KeepSake/VERIFIER.md) have been empirically satisfied and documented in [`PROGRESS.md`](file:///Users/vikramaditya/Disk/Projects/KeepSake/PROGRESS.md).
- The 19-photo ground-truth dataset confirms zero false merges, zero Cannot-Link violations, correct multi-photo galleries, and robust user-confirmed identity matching.

---

## 2. Hard Circuit Breakers (Immediate Stop Required)

The agent must **HALT IMMEDIATELY** and request user guidance under the following conditions:

### 2.1 Three Consecutive Unsuccessful Verification Attempts
- If the same specific issue (e.g. model compilation failure, test regression, or clustering failure) fails verification **three consecutive times** without a materially different approach:
  - **STOP**.
  - Document in `PROGRESS.md`:
    1. The exact issue and error log.
    2. The three distinct attempts and why each failed.
    3. The smallest specific decision or clarification needed from the user.

### 2.2 Missing External Resource, Permission, or Dependency
- If a required resource cannot be acquired locally without external user action (e.g. downloading/converting an external model weight file, Apple developer code-signing provisioning, missing system framework permissions):
  - **STOP**.
  - Do not attempt speculative workarounds or fabricate mock assets.
  - Clearly state the missing asset and provide the exact command or path required.

### 2.3 Risk to User Data or Photos
- If an operation could potentially delete, overwrite, or mutate original user photo files:
  - **STOP IMMEDIATELY**. KeepSake is strictly non-destructive.
- If an operation could wipe or corrupt persistent user identity profiles (`library_index.json` user-curated names or manual links):
  - **STOP**. Backup the store before any structural migration.

### 2.4 Major Architectural or Product Decision Needed
- If progress depends on a choice between mutually incompatible product behaviors (e.g. changing from an automated clustering model to a semi-supervised confirmation queue, or deciding how ambiguous faces should be presented in the UI):
  - **STOP**.
  - Formulate the concrete options, trade-offs, and recommend the best path.

### 2.5 Speculative or Untestable Scenarios
- If further changes cannot be verified empirically with the available codebase, tests, or dataset:
  - **STOP**.
  - Do not write speculative, unverified code.

### 2.6 Model Licensing or Distribution Restrictions
- If the selected recognition model has licensing constraints incompatible with the application distribution (e.g. non-commercial restrictions on certain InsightFace pretrained weights if intended for commercial distribution):
  - **STOP** and bring the licensing terms to the user's attention.

---

## 3. Strict Invariant Protections (Never Permitted)

Under **NO** circumstances may an agent loop:
1. ❌ **Weaken Verification Criteria**: Never delete assertions, loosen margins, or skip tests to make a run pass.
2. ❌ **Lower Thresholds Arbitrarily**: Never lower global cosine thresholds (e.g. to 0.40 or 0.45) just to force People card counts down when it induces false merges.
3. ❌ **Fake Model Backends**: Never pretend a neural network is running by returning synthetic DCT/Fourier projections or random noise while logging that a real model is active.
4. ❌ **Violate Cannot-Link**: Never allow two faces from the same photograph to merge into the same person identity.
5. ❌ **Overwrite User Curation**: Never overwrite user-assigned custom names or manual face assignments.

---

## 4. Resumption Protocol

When the loop stops due to a circuit breaker:
1. Update `PROGRESS.md` with current state, failure logs, and the blocking condition.
2. Explain the blocker concisely in the chat response.
3. Propose the single smallest decision or next action needed from the user.
4. Await user instructions before resuming work.
