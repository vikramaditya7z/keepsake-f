# Project Rules — Keepsake

These rules define the engineering standards, architecture principles, and development practices for the Keepsake macOS application. All development on this repository must strictly adhere to these guidelines.

---

## 1. Core Rule & Mandatory Check

> **Before implementing a new feature, read [`PROJECT_RULES.md`](file:///Users/vikramaditya/Disk/Projects/KeepSake/PROJECT_RULES.md) and [`ARCHITECTURE.md`](file:///Users/vikramaditya/Disk/Projects/KeepSake/ARCHITECTURE.md) and ensure the proposed implementation follows them.**

---

## 2. Privacy & Local-First Principles

- **100% Local-First Processing**: All photo scanning, face detection, face recognition/embedding extraction, similarity clustering, indexing, and storage must execute strictly locally on the user's Mac.
- **Zero Unauthorized Cloud Exfiltration**: Never upload user photos, metadata, facial embeddings, thumbnails, or derived personal data to external servers or cloud services without explicit future user consent.
- **No Unjustified Networking**: The core application logic must function completely offline without requiring network connectivity or third-party web services.
- **No Backend / Server by Default**: Do not introduce a server or cloud backend unless there is a compelling, explicitly approved requirement.

---

## 3. Technology Stack & Native Apple Ecosystem

- **Swift & SwiftUI**: Swift and SwiftUI are the primary programming language and UI framework for Keepsake.
- **Prefer Native macOS / Apple APIs**: Use native frameworks (e.g., AppKit/SwiftUI integrations, Vision, Core Graphics, Core ML, FileSystem APIs, Swift Concurrency) whenever suitable before evaluating external third-party dependencies.
- **Minimal & Justified Dependencies**: Keep external packages to an absolute minimum. Any external dependency must provide substantial value that cannot be cleanly achieved using native platform APIs.

---

## 4. Architecture & Modularity

- **Clear Separation of Concerns**: Keep clean boundaries between:
  - **User Interface (UI)**: SwiftUI views, view models, and visual states.
  - **Application / Coordination Logic**: Controllers, pipeline coordinators, and state orchestration.
  - **Data / Storage**: Local persistence, index storage, metadata caching.
  - **ML / Computer Vision (CV)**: Face detection, embedding extraction, and clustering algorithms.
- **Interchangeable ML Implementations**: ML/CV layers should be behind well-defined, decoupled protocols so models or backends (e.g., Vision framework, Core ML, custom ONNX/C++ bindings) can be improved or swapped without rewriting UI or data pipelines.
- **Focused, Understandable Modules**: Keep files, structs, and classes small, cohesive, and easy to reason about.
- **Avoid Premature Abstractions**: Write clear, direct code. Do not introduce speculative generics, complex inheritance hierarchies, or excessive protocol layers until proven necessary.
- **No Premature Optimization**: Focus on clean, correct code first. Profile with Instruments when optimizing performance for large photo collections.

---

## 5. Incremental Development & Scope Discipline

- **Build Only What Is Requested**: Do not implement future features, speculative APIs, or placeholder stub systems ahead of time.
- **Small, Reviewable Changes**: Make focused, incremental improvements that can be easily inspected and tested.
- **Do Not Modify Unrelated Code**: Keep diffs tightly scoped to the specific feature, bug fix, or refactor at hand.
- **Document Architectural Evolution**: When the architecture changes materially, update [`ARCHITECTURE.md`](file:///Users/vikramaditya/Disk/Projects/KeepSake/ARCHITECTURE.md) in the same change.

---

## 6. Code Quality, Error Handling & Reliability

- **Deterministic & Testable Logic**: Structure business logic and data processing in a deterministic manner that is straightforward to unit test.
- **Explicit Error Handling**: Always handle errors explicitly using Swift's native error handling (`throws`, `Result`, typed errors). Do not silently swallow or discard errors (e.g., avoid unchecked `try?` in critical data paths).
- **Concurrency Safety**: Use Swift Structured Concurrency (`async`/`await`, `Task`, actors) for asynchronous photo processing, background pipeline tasks, and main-thread UI synchronization.
- **Build & Test Verification**: Verify builds and run test suites after every meaningful change. Ensure the application compiles without warnings or errors.
