# Connection guardian policy review

`GuardianPolicyTests.m` passes **193 hardware-free assertions**: 61 against production pure policy functions and 37 around production End Session transitions with a fake environment. The latter execute the real asynchronous `endSession`/`pause` methods, repair/service completion closures, and state-only launch-result handoff. They cover eight End scenarios, including the duplicate-End generation race. Test controllers bypass the initializer that starts observation; they create no timer. Process lookups are trapped and must remain unused. No live process enumeration, USB access, app launch or signal occurs.

The fake helper boundary stores and later calls the actual production completion closure; it does not launch an `NSTask` or test the real termination handler. Process presence, quit-target verification and normal-quit delivery are substituted environment methods. The launch-result fixture begins after the OS-facing callback has verified an identity. These checks do not validate real normal-quit delivery, successful Force Quit, LaunchServices timing, helper watchdogs or camera behavior. The broader asynchronous cases below remain an **unexecuted oracle** unless marked as fixture-tested in `policy-cases.json`. The separate official-Tether capture/control baseline is not a Guardian hardware validation.

The public controller API is asynchronous (`start`, `pause`, `endSession`, `reconnect`, `forceRestart`, `forceQuit`, `openTether`, `stopToolWithCompletion:`). Snapshots include `ending_session`, `session_ended`, separate `can_force_quit`/`can_force_restart` flags, `force_action`, observation-validity flags and `capture_state`. Process observations expire after two seconds and USB inspection after four. A running process, present USB device or claimed interface never proves that shooting works or a transfer has finished. State labels may change; assertions should target actions and externally relevant facts, not text or incidental callback order.

## Invariants

- A running Tether process may be capturing or downloading even when it is in the background. No new USB recovery helper is started while it is known to be running. Automatic recovery never force-terminates or signals it. The accepted narrow exception is a confirmed physical USB detach: while supervision is enabled, the guardian may request a **normal quit only of its own previously launched, freshly identity-validated Tether process**. It waits for that application to finish; this is not a proof that capture or file saving has completed.
- `reconnect` is an explicit request to quit normally and restore the connection. A 30-second expiry merely means Tether has not exited; it does not prove a deadlock or that capture is idle. Force termination needs the separate `forceRestart` action and a fresh match of PID, UID, executable identity and process start time.
- `pause` and tool quit cancel future guardian actions and invalidate old completions. They do not quit Tether or terminate an importer/camera application. A passive inspector may be cancelled; an in-flight USB recovery or guarded service helper is allowed to finish within its own bound and its result is then discarded. The guardian does not interrupt a PTP transaction merely to make Pause/Quit appear immediate.
- `endSession` first disables recovery and invalidates previous operations, waits for owned preparation or an accepted launch to resolve, then requests a normal quit of one verified Tether target. It never automatically relaunches or force-terminates Tether. Duplicate End preserves an already-pending quit generation and identity. A failed or changed target is not automatically replaced by a later process. Pause cancels the remaining End wait; a normal quit already delivered cannot be withdrawn. `forceQuit` is a separate explicit action and cannot consume `forceRestart` consent, or vice versa.
- Every child completion belongs to the operation generation and child identity that launched it. A cancelled or stale exit code zero cannot cause “ready”, auto-launch or further service/USB work.
- A detector failure is an error/unknown state. It is never a certified absent camera, free interface or successful handoff.
- Only a completed, successful recovery permits automatic Tether launch, after a fresh camera/process check. A service-guard refusal, drain failure, helper watchdog exit or lost child is not success.
- Duplicate attach/inspection events do not create concurrent helpers. Retries are bounded per camera attachment/action generation and do not turn refusals into a service-kill loop.
- A changed USB registry/interface identity invalidates old ownership evidence. Process names and PIDs alone do not establish identity; PID reuse never authorizes termination.

## Focused fault cases

| Case | Injection | Required observable result |
| --- | --- | --- |
| Camera arrives during an active capture | Tether running before `start`/attach | No new USB recovery, service restart or force termination; attach alone does not request a quit |
| Confirmed physical detach of managed Tether | Supervision enabled; exact previously launched Tether identity still matches | A normal quit request may be sent; no automatic force termination or USB recovery while the app remains alive |
| Normal reconnect still waiting | Explicit `reconnect`; same Tether process remains for 30 seconds | Waiting/explicit-force state; zero automatic force signals |
| New Tether instance replaces old one | Old quit target exits; same PID with new start time, or new PID, appears before `forceRestart` | Refuse stale force target; never signal the replacement based on old consent/evidence |
| Pause races a successful probe | Probe launched, `pause`, then old child reports exit zero | In-flight recovery finishes within its existing bound; no Tether launch or ready transition from old result |
| Quit races a successful probe | `stopToolWithCompletion:`, then delayed inspect/probe callbacks | Completion once after own child settles; no new work or Tether launch |
| Manual Tether launch races repair | Process appears after initial inspection, before/during probe | Invalidate the result, allow the already-started recovery to finish within its bound, leave Tether alone; no additional repair/service stage or auto-launch |
| Inspection fails | Inspector times out, malformed JSON or `inspection_error` | Error/unknown UI state; no assumption of absent camera/free owner |
| Owner identity changes during restart | Registry owner or process start time changes after inspection | Guard refusal; no signal to new identity, no USB probe on claimed release |
| Multiple matching cameras | Inspector reports two devices or interfaces | Refusal; no arbitrary selection, service signal or auto-launch |
| Repeated attach notifications | Several attach/inspection results arrive before first helper exits | At most one owned helper; no duplicate launch |
| Detach and re-enumeration | Interface A disappears and B arrives while A's helper/result is pending | Invalidate A; new operation may use B only after its own fresh checks |
| Recovery never becomes ready | Repeated open/drain/session failures | Bounded retries/backoff, honest failure state, no forced Tether termination |
| Official app already hung | Tether process remains alive and does not acknowledge normal quit | No claim of camera repair; explicit user decision is required before any force termination |

## End Session fixtures executed

| Scenario | Production behavior checked with fake boundaries |
| --- | --- |
| Direct End and duplicate End | Recovery revoked first; one quit target; duplicate preserves generation and queued quit; Start/Reconnect/Open cannot override End; Force Restart rejected |
| End during USB preparation | Owned helper remains alive; late success cannot inspect, restart services or launch; reliable absence settles End |
| End during service release | Late successful release cannot begin a new USB repair |
| End during accepted launch | Late handoff retains the owned identity, then requests normal quit without restoring recovery or running-success status |
| Cancel End during launch | Late launch completion leaves Tether alone and preserves Paused status |
| Cancel End during repair | Old success neither launches nor falsely declares the session ended |
| Unknown process observation | No quit target and no ended claim; later reliable absence can settle |
| Rejected or changed quit target | One attempt only; manual attention without selecting a later process or restarting |

## Existing helper boundaries

`恢复S1H连接.command --check` is static and camera-free; `--diagnose` invokes read-only service inspection. Normal recovery opens USB and launches official Tether after success, so it is not a read-only detector. Its initial process-name check is not an atomic exclusion mechanism against a later manual Tether launch.

`s1h_camera_service --inspect` reports `client_state: unknown`. IORegistry ownership cannot prove that every ImageCaptureCore/XPC client is idle. Real service-helper modes have an 18-second self-only exit watchdog; pure tests and help do not schedule it. The opt-in restart helper rechecks known camera apps, interface owner, PID, UID, path and start time before signals. Its service TERM/KILL waits are bounded. Existing guard simulation tests cover identity reuse and ownership release races; they do not validate a guardian's callback cancellation or Tether lifecycle.

`s1h_iousbhost_probe --io-buffer --drain-input` has an 18-second process watchdog and structured exit stages (20 missing interface, 21 ambiguous, 22 open, 23 drain, 24 session, 25 identity changed, 124 watchdog). Its normal supervisor deadline should allow that bound, rather than force-ending it early. The probe does not currently implement graceful SIGTERM session cleanup. Cancelling it releases the process/interface but may leave camera protocol state uncertain; cancelled work must not be declared a successful repair.

## Limits that must remain explicit

A background supervisor does not fix official Tether's internal main-thread/worker shutdown dependency. It also cannot keep the USB interface permanently exclusive while allowing Tether's own camera service to use it. It can prepare a connection while camera clients are closed, hand it to Tether, monitor lifecycles, and offer bounded recovery after exit.

Process observation and launching/signalling another process are separate operations on macOS. A manual launch can occur between the final check and USB work. Fresh process checks, launch-generation validation and discarding results when Tether appears reduce this race; they cannot justify an absolute claim of zero in-flight overlap. An already-submitted recovery is allowed to finish its bounded transaction sequence rather than being terminated mid-PTP. Any transaction already submitted may have to finish or be abandoned before the interface is released.

## Run the hardware-free checks

```sh
clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks -Wall -Wextra -Werror -O2 tests/GuardianPolicyTests.m -framework Cocoa -framework Security -o build/guardian-policy-tests
./build/guardian-policy-tests
```

The test translation unit imports `GuardianController.m` to call production functions and transitions. Asynchronous public methods run on the fixture's serial queue; fake helper completions are injected deterministically. Freshness boundaries use explicit monotonic-clock values in the production pure function. No real system controller initializer is called. Passing these checks cannot establish hot-plug reliability, successful official capture after a restart, or that a manual launch can never overlap previously submitted USB work.

## 0.2.2 regression coverage

Current build passes 193 controller checks and 50 event-writer checks. Open cannot bypass fresh inspection, strict repair and the post-repair check. Preview blockers retain pending intent, deduplicate events, and do not consume I/O retry counts; three consecutive post-repair blocker arrivals are covered. Existing official Tether remains untouched.
