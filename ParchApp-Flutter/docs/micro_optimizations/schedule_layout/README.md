# Schedule layout micro-optimization

## Problem

The Schedule timeline constructs a set of hourly lines every time its view is built. The time column wrapped each line in a `SizedBox`, `Row`, `Expanded`, and `Container`, although `Positioned` already supplies its width. The two schedule lanes were also wrapped in an additional `Expanded` and `Row`. These wrappers add widget and layout work without adding a visual or behavioral requirement.

The changes are limited to `lib/features/schedule/presentation/views/schedule_view.dart`. The existing `Stack`, `Positioned`, scrolling, event layout, padding, and state are preserved. The personal and friend event block layouts were inspected but kept: their decoration, padding, constraints, `LayoutBuilder`, `Row`, and `Expanded` affect appearance or behavior.

## Before

`_buildTimeColumn()`:

```dart
Positioned(
  top: (hour - _startHour) * 60.0,
  left: 0, right: 0,
  child: SizedBox(
    height: 1,
    child: Row(children: [
      Expanded(child: Container(height: 1, color: const Color(0xFFE2E8F0))),
    ]),
  ),
)
```

`_hourLines()`:

```dart
Positioned(
  top: index * 60.0, left: 0, right: 0,
  child: Container(height: 1, color: const Color(0xFFE8EDF5)),
)
```

`_buildScheduleContent()`:

```dart
Row(children: [
  _buildTimeColumn(),
  Expanded(child: Row(children: [
    Expanded(child: _buildMyScheduleLane(state)),
    Expanded(child: _buildFriendsLane(state)),
  ])),
])
```

## After

`_buildTimeColumn()`:

```dart
Positioned(
  top: (hour - _startHour) * 60.0,
  left: 0, right: 0,
  child: const SizedBox(height: 1, child: ColoredBox(color: Color(0xFFE2E8F0))),
)
```

`_hourLines()`:

```dart
Positioned(
  top: index * 60.0, left: 0, right: 0, height: 1,
  child: const ColoredBox(color: Color(0xFFE8EDF5)),
)
```

`_buildScheduleContent()`:

```dart
Row(children: [
  _buildTimeColumn(),
  Expanded(child: _buildMyScheduleLane(state)),
  Expanded(child: _buildFriendsLane(state)),
])
```

## Strategy and structural improvement

The strategy is **avoid deeply nested layouts**: remove wrappers when existing parent constraints already express the same geometry. Both lanes retain equal `Expanded` widths after the fixed 62-pixel time column. Grid line positions, thicknesses and colors remain unchanged.

| Location | Original hierarchy | Optimized hierarchy | Source widgets removed | Repetitions |
|---|---|---|---:|---:|
| Time lines | `Positioned → SizedBox → Row → Expanded → Container` | `Positioned → SizedBox → ColoredBox` | 2 net per line | 11 |
| Lane grid lines | `Positioned → Container(height, color)` | `Positioned(height) → ColoredBox` | 0 net declared; removes the `Container` and its implicit constraint wrapper at runtime | 22 (11 per lane) |
| Lane layout | `Expanded → Row → 2 × Expanded` | `2 × Expanded` | 2 | 1 |

The explicit source hierarchy contains **24 fewer widget declarations across one timeline** (22 from time lines and 2 from the lane wrapper). The 22 lane lines replace `Container` with `ColoredBox`; their source declaration count is unchanged, but `Container`'s additional internal layout widget is no longer needed. This is a structural count, not a measured frame-time improvement.

## Validation and limits

- `test/features/schedule/schedule_layout_test.dart` checks lane ordering and positions, personal/friend blocks, selected common slots, and layout at 320, 390 and 430 logical pixels.
- At 320 px, an existing 25 px horizontal `RenderFlex` overflow was reproduced with both the original and optimized file; the test records this known baseline. The changes do not fix this unrelated existing overflow.
- `test/visual_restoration_test.dart` generated the Schedule screenshot at 390 × 844 before and after. The PNG files had identical SHA-256 hashes (`76ab4613cc4e4237ef937c3ba88c07e1004d2cdf21759d47b5fd3851558a8aa1`). This is evidence for that particular fixture and viewport, not a guarantee for every device or state.

## Performance evidence

The BEFORE measurements were supplied from Flutter DevTools on iOS in profile mode (Flutter 3.47.0, DevTools 2.60.0, 884 frames). They are global frame metrics and do **not** isolate Schedule layout time.

| Metric | BEFORE | AFTER |
|---|---:|---:|
| UI average | 5.29 ms | Pending |
| UI median | 4.46 ms | Pending |
| UI p95 | 14.09 ms | Pending |
| Raster average | 0.63 ms | Pending |
| Raster p95 | 1.38 ms | Pending |
| UI frames above 16.67 ms | 11 / 884 | Pending |
| Maximum UI frame duration | 37.18 ms | Pending |

### AFTER measurement procedure

1. Use the same iOS device, OS, Flutter 3.47.0, DevTools 2.60.0, build configuration, account, data and network conditions as BEFORE. Build this branch in **profile** mode (`flutter run --profile`); do not use debug mode.
2. Open Flutter DevTools Performance, enable the same tracing settings used for BEFORE, and warm up using the same steps. Clear the timeline before recording.
3. Repeat the same Schedule navigation, duration, scrolling, and interaction sequence as the original 884-frame recording, for a comparable duration. Avoid unrelated background activity.
4. Export/save the timeline and record the frame count, UI average/median/p95/max, raster average/p95 and frames above 16.67 ms. Repeat runs and retain raw evidence; compare like-for-like runs rather than selecting only the best.
5. Fill in the AFTER column only with actual measured data, and report variability and limitations. No AFTER performance claim is made by these code changes alone.
